import AVFoundation
import CoreAudio
import Network

/// Receives browser camera/mic over WSS: one binary message = type byte + payload.
final class PhoneMediaServer {
    // Receives camera + mic from a modern iPhone's browser over a secure WebSocket.
    // Each binary message: 1 type byte + payload.  'H' token  ·  'V' JPEG frame  ·  'A' 16 kHz mono s16le PCM
    private let queue = DispatchQueue(label: "phone-media")
    private let token: String
    private let audio: AudioOut?
    private let lock = NSLock()
    private var _latestFrame: Data?
    private var _lastFrameAt = Date.distantPast
    private var wsListener: NWListener?
    private let sessions = MediaSessionBudget()
    private var connections: [UUID: MediaWebSocketConnection] = [:]
    private let authenticationTimeout: TimeInterval
    var onFrame: ((Data) -> Void)?

    var latestFrame: Data? { lock.lock(); defer { lock.unlock() }; return _latestFrame }
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(_lastFrameAt) < 2 }

    init(token: String, audio: AudioOut?, authenticationTimeout: TimeInterval = 5) {
        self.token = token
        self.audio = audio
        self.authenticationTimeout = authenticationTimeout
    }

    private func handle(_ message: PhoneMediaMessage) {
        switch message {
        case .video(let payload):
            lock.lock(); _latestFrame = payload; _lastFrameAt = Date(); lock.unlock()
            onFrame?(payload)
        case .audio(let payload):
            audio?.play(pcm16: payload)
        case .authentication: break
        }
    }

    func startWebSocket(port: UInt16, identity: sec_identity_t) throws {
        try startWebSocket(parameters: LocalTLS.parameters(identity, websocket: true), on: NWEndpoint.Port(rawValue: port)!)
    }

    // Parameters are injectable for local Network.framework tests without certificates or app startup.
    func startWebSocket(parameters: NWParameters, on port: NWEndpoint.Port) throws {
        let ws = try NWListener(using: parameters, on: port)
        ws.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            self.accept(conn)
        }
        ws.start(queue: queue)
        wsListener = ws
    }

    var listeningPort: NWEndpoint.Port? { wsListener?.port }
    var resourceCounts: (connections: Int, producers: Int) {
        queue.sync { (sessions.count, sessions.producer == nil ? 0 : 1) }
    }

    func stop() {
        queue.sync {
            wsListener?.cancel()
            for connection in Array(connections.values) { connection.close() }
        }
    }

    private func accept(_ conn: NWConnection) {
        guard let id = sessions.acquire() else { conn.cancel(); return }
        let connection = MediaWebSocketConnection(conn, id: id, sessions: sessions, token: token,
            queue: queue, authenticationTimeout: authenticationTimeout,
            handle: { [weak self] in self?.handle($0) },
            onClose: { [weak self] in self?.connections[id] = nil })
        connections[id] = connection
        connection.start()
    }
}

/// All state, timer, receive and cleanup callbacks run on PhoneMediaServer's queue.
private final class MediaWebSocketConnection {
    private let conn: NWConnection
    private let id: UUID
    private let sessions: MediaSessionBudget
    private let token: String
    private let queue: DispatchQueue
    private let authenticationTimeout: TimeInterval
    private let handle: (PhoneMediaMessage) -> Void
    private var onClose: (() -> Void)?
    private var deadline: DispatchWorkItem?
    private var becameReady = false
    private var closed = false

    init(_ conn: NWConnection, id: UUID, sessions: MediaSessionBudget, token: String,
         queue: DispatchQueue, authenticationTimeout: TimeInterval,
         handle: @escaping (PhoneMediaMessage) -> Void, onClose: @escaping () -> Void) {
        self.conn = conn
        self.id = id
        self.sessions = sessions
        self.token = token
        self.queue = queue
        self.authenticationTimeout = authenticationTimeout
        self.handle = handle
        self.onClose = onClose
    }

    deinit { conn.cancel() }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                guard !self.becameReady else { return }
                self.becameReady = true
                if self.sessions.producer != self.id {
                    let work = DispatchWorkItem { [weak self] in self?.close() }
                    self.deadline = work
                    self.queue.asyncAfter(deadline: .now() + self.authenticationTimeout, execute: work)
                }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        deadline = nil
        sessions.release(id)
        conn.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func receive() {
        conn.receiveMessage { [weak self] data, context, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                self.close(); return
            }
            switch metadata.opcode {
            case .ping, .pong:
                // autoReplyPing remains enabled; control traffic cannot authenticate or extend the deadline.
                self.receive(); return
            case .binary: break
            default: self.close(); return
            }
            guard complete, let data,
                  let message = PhoneMediaMessage.parse(data, authenticated: self.sessions.producer == self.id, token: self.token) else {
                self.close(); return
            }
            if message == .authentication {
                guard self.sessions.authenticate(self.id) else { self.close(); return }
                self.deadline?.cancel()
                self.deadline = nil
            } else { self.handle(message) }
            self.receive()
        }
    }
}

/// Plays the phone's mic into an output device — normally the BlackHole virtual device,
/// so other apps can pick "BlackHole 2ch" as their microphone.
final class AudioOut {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let queuedAudio = AudioQueueBudget()
    let deviceName: String

    /// Returns nil (and explains why) if no output device matches `deviceMatch`.
    init?(deviceMatch: String) {
        guard let (id, name) = AudioOut.findOutputDevice(matching: deviceMatch) else {
            print("⚠️  No audio device matching \"\(deviceMatch)\" — install BlackHole 2ch to use the phone as a mic.")
            return nil
        }
        deviceName = name
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        var devID = id
        guard let unit = engine.outputNode.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &devID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            print("⚠️  Could not route audio to \(name)")
            return nil
        }
        do { try engine.start() } catch { print("⚠️  Audio engine failed: \(error)"); return nil }
        player.play()
    }

    func play(pcm16 data: Data) {
        guard let frames = queuedAudio.reserve(bytes: data.count) else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            queuedAudio.complete(frames: frames)
            return
        }
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let sample = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                out[i] = Float(Int16(littleEndian: sample)) / 32768
            }
        }
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [queuedAudio] _ in
            queuedAudio.complete(frames: frames)
        }
    }

    static func findOutputDevice(matching match: String) -> (AudioDeviceID, String)? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
                  let n = name?.takeRetainedValue() as String?,
                  n.localizedCaseInsensitiveContains(match) else { continue }
            // Must be able to output audio.
            var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                         mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize)
            if streamsSize > 0 { return (id, n) }
        }
        return nil
    }
}
