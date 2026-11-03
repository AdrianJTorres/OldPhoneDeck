import Foundation

/// Shared by the HTTP and HTTPS listeners. A closed connection returns its lease once.
final class HTTPConnectionBudget {
    let limit: Int
    private let lock = NSLock()
    private var used = 0

    init(limit: Int = 32) { precondition(limit > 0); self.limit = limit }

    var count: Int { lock.lock(); defer { lock.unlock() }; return used }

    func acquire() -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard used < limit else { return nil }
        used += 1
        return Lease(self)
    }

    private func release() {
        lock.lock(); defer { lock.unlock() }
        used -= 1
        precondition(used >= 0)
    }

    final class Lease {
        private let lock = NSLock()
        private var budget: HTTPConnectionBudget?
        fileprivate init(_ budget: HTTPConnectionBudget) { self.budget = budget }

        func release() {
            lock.lock()
            let owner = budget
            budget = nil
            lock.unlock()
            owner?.release()
        }

        deinit { release() }
    }
}

/// At most one queued delivery and one latest pending JPEG, even if the destination stalls.
final class LatestFrameHandoff {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let deliver: (Data) -> Void
    private var pending: Data?
    private var scheduled = false

    init(queue: DispatchQueue, deliver: @escaping (Data) -> Void) {
        self.queue = queue
        self.deliver = deliver
    }

    func submit(_ jpeg: Data) {
        lock.lock()
        pending = jpeg
        let enqueue = !scheduled
        scheduled = true
        lock.unlock()
        if enqueue { queue.async { self.drain() } }
    }

    private func drain() {
        lock.lock()
        let frame = pending
        pending = nil
        lock.unlock()
        if let frame { deliver(frame) }
        lock.lock()
        let again = pending != nil
        if !again { scheduled = false }
        lock.unlock()
        if again { queue.async { self.drain() } }
    }
}

/// Accessed only on PhoneMediaServer's serial queue, including terminal callbacks.
final class MediaSessionBudget {
    private var sessions: Set<UUID> = []
    private(set) var producer: UUID?
    var count: Int { sessions.count }

    func acquire() -> UUID? {
        guard sessions.count < 2 else { return nil }
        let id = UUID()
        sessions.insert(id)
        return id
    }

    func authenticate(_ id: UUID) -> Bool {
        guard sessions.contains(id), producer == nil else { return false }
        producer = id
        return true
    }

    func release(_ id: UUID) {
        guard sessions.remove(id) != nil else { return }
        if producer == id { producer = nil }
    }
}

enum PhoneMediaMessage: Equatable {
    static let maximumMessageSize = 2 * 1024 * 1024
    static let maximumAudioBytes = 8 * 1024
    case authentication, video(Data), audio(Data)

    /// Called only for complete binary WebSocket messages. No payload is copied before validation.
    static func parse(_ data: Data, authenticated: Bool, token: String) -> PhoneMediaMessage? {
        guard data.count <= maximumMessageSize, let type = data.first else { return nil }
        let payload = data.dropFirst()
        if !authenticated {
            guard data.count <= 256, type == UInt8(ascii: "H"), payload.elementsEqual(token.utf8) else { return nil }
            return .authentication
        }
        switch type {
        case UInt8(ascii: "V"):
            // Check the JPEG envelope without decoding or retaining another image.
            guard payload.count >= 4, payload.prefix(2).elementsEqual([0xff, 0xd8]),
                  payload.suffix(2).elementsEqual([0xff, 0xd9]) else { return nil }
            return .video(Data(payload))
        case UInt8(ascii: "A"):
            guard payload.count <= maximumAudioBytes, payload.count.isMultiple(of: 2) else { return nil }
            return .audio(Data(payload))
        default: return nil
        }
    }
}

/// Reserves the proposed PCM frame total before buffer allocation/conversion.
final class AudioQueueBudget {
    let limit = 4000 // 250 ms at 16 kHz
    private let lock = NSLock()
    private var queued = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return queued }

    func reserve(bytes: Int) -> Int? {
        guard bytes > 0, bytes <= PhoneMediaMessage.maximumAudioBytes, bytes.isMultiple(of: 2) else { return nil }
        let frames = bytes / 2
        lock.lock(); defer { lock.unlock() }
        guard frames <= limit - queued else { return nil }
        queued += frames
        return frames
    }

    func complete(frames: Int) {
        lock.lock(); defer { lock.unlock() }
        precondition(frames > 0 && frames <= queued)
        queued -= frames
    }
}
