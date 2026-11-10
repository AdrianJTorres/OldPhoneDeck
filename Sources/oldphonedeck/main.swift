import AppKit
import ApplicationServices

// MARK: Options

struct Options {
    var port: UInt16 = 8045                // http = port, https = port+2, secure WebSocket = port+3
    var managedStartup = false
    var micDevice = "BlackHole"            // output device that receives a modern iPhone's mic
    var configDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck")

    enum ConfigDirError: Error, Equatable, CustomStringConvertible {
        case missingValue, empty, flagLike(String)
        var description: String {
            switch self {
            case .missingValue: return "--config-dir requires PATH (try --help)"
            case .empty: return "--config-dir requires a non-empty PATH (try --help)"
            case .flagLike(let value): return "--config-dir requires PATH, got option \(value) (try --help)"
            }
        }
    }

    /// Expands `~`, resolves a relative path against the current directory and standardizes the
    /// result. Separate from `init` so tests can prove resolution without exiting the process.
    static func resolveConfigDir(_ raw: String?) throws -> URL {
        guard let raw else { throw ConfigDirError.missingValue }
        guard !raw.isEmpty else { throw ConfigDirError.empty }
        guard !raw.hasPrefix("-") else { throw ConfigDirError.flagLike(raw) }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Creates the configuration directory with `0700` when it does not exist, mirroring
    /// `POSIXConfigurationFile.createDirectory` (ADR-016): an existing directory keeps its current
    /// mode — the production `~/.oldphonedeck` is `0755` today and this has no business changing
    /// it. The mode is applied explicitly to the leaf, which will hold the token and the TLS
    /// identity; intermediates keep the process default.
    static func createConfigDir(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--managed-startup": managedStartup = true
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "--mic-device": micDevice = it.next() ?? micDevice
            case "--config-dir":
                do {
                    configDir = try Options.resolveConfigDir(it.next())
                    // Created up front so an isolated instance fails here rather than falling
                    // back to the production directory silently at first use.
                    try Options.createConfigDir(configDir)
                } catch let e as ConfigDirError { print(e.description); exit(2) }
                catch { print("--config-dir is unusable: \(error.localizedDescription)"); exit(2) }
            case "-h", "--help":
                print("""
                oldphonedeck: turn an old iPhone into a Stream Deck-style control panel for your Mac
                  --managed-startup require existing V2/token/TLS; lock instance and fail on startup errors
                  --port N          HTTP port (default 8045; HTTPS uses N+2, WebSocket N+3)
                  --mic-device NAME audio device that receives the phone's mic (default BlackHole)
                  --config-dir PATH configuration directory for the token, launcher config and TLS
                                    (default ~/.oldphonedeck; the app catalog is never redirected)
                """)
                exit(0)
            default: print("Unknown option \(a) (try --help)"); exit(2)
            }
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options(CommandLine.arguments)
let configDir = opts.configDir
// --config-dir redirects the token, the configuration store and the TLS material; the application
// catalog (Apps.list) keeps scanning the real application directories.
LocalTLS.use(configDir: configDir)
let configStore = ConfigurationStore(directory: configDir)

// MARK: Access token (anyone on the Wi-Fi could otherwise open apps on your Mac)

func loadToken() -> String {
    let file = configDir.appendingPathComponent("token")
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    if opts.managedStartup { ManagedStartup.report("existing token could not be loaded"); exit(1) }
    let t = (0..<12).map { _ in String("abcdefghjkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? t.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return t
}

func lanAddress() -> String {
    var addr = "localhost"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addr }
    defer { freeifaddrs(ifaddr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = p.pointee
        guard i.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: i.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        addr = String(cString: host)
        if name == "en0" { break }
    }
    return addr
}

let startup: ManagedStartup?
if opts.managedStartup {
    do { startup = try ManagedStartup(directory: configDir, port: opts.port, address: lanAddress()) }
    catch {
        ManagedStartup.report((error as? ManagedStartup.Failure)?.rawValue ?? "preflight failed")
        exit(1)
    }
} else { startup = nil }
startup?.armDeadline()
let token = loadToken()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: Services

let server: HTTPServer
let httpBudget = HTTPConnectionBudget()
do { server = try HTTPServer(port: opts.port, budget: httpBudget) } catch { ManagedStartup.report("HTTP listener creation failed"); exit(1) }
server.onListenerState = { startup?.observe($0, service: "HTTP") }

// Camera + mic from a modern iPhone (browser, over the secure WebSocket).
let cameraViewers = MJPEGViewers() // touched only on server.queue
let frameHandoff = LatestFrameHandoff(queue: server.queue) { cameraViewers.pushFrame($0) }
let phoneMedia = PhoneMediaServer(token: token, audio: AudioOut(deviceMatch: opts.micDevice))
phoneMedia.onFrame = { jpeg in
    frameHandoff.submit(jpeg)
}

let stats = Stats()
stats.start()
let music = Music()
music.start()

// Approved-action boundary: the only route from a request to an approved macOS action.
let shortcuts = ShortcutService(approvals: ShortcutApprovals.load(directory: configDir), runner: BoundedShortcutRunner())
let actions = ActionRegistry(shortcuts: shortcuts)

// MARK: Routes

let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)!

// One application policy receives trusted connection metadata from both listeners.
let admission: HTTPTransportAdmission = { DeckRoute.admit($0, token: token, transport: $1) }
let routes: (HTTPRequest, HTTPConnection) -> Void = { req, conn in
    guard let route = DeckRoute.match(method: req.method, path: req.path) else {
        return conn.respond(404, text: "not found")
    }
    if let failure = DeckRoute.validateParameters(req) {
        return conn.respond(failure.status, text: failure.message)
    }
    let p = req.params
    switch route {
    case .profile:
        guard let der = try? Data(contentsOf: LocalTLS.caDER) else { return conn.respond(404, text: "no certificate yet") }
        let cert: [String: Any] = [
            "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadIdentifier": "com.oldphonedeck.ca.cert", "PayloadUUID": "6F1C2A4E-2B7D-4C5A-9E1F-50A1C0DEC0A1",
            "PayloadDisplayName": "OldPhoneDeck CA", "PayloadCertificateFileName": "oldphonedeck-ca.cer", "PayloadContent": der,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "com.oldphonedeck.ca", "PayloadUUID": "3B8E9D10-7C2F-4E61-A5B3-50A1C0DEC0A2",
            "PayloadDisplayName": "OldPhoneDeck", "PayloadOrganization": "OldPhoneDeck",
            "PayloadDescription": "Lets this iPhone open OldPhoneDeck on your Mac over HTTPS (needed for camera, mic and voice).",
            "PayloadContent": [cert],
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
        return conn.respond(200, "application/x-apple-aspen-config", data)
    case .page, .index:
        let html = (try? Data(contentsOf: webRoot.appendingPathComponent("index.html"))) ?? Data()
        return conn.respond(200, "text/html; charset=utf-8", html)

    case .info:
        conn.respondJSON(["camera": phoneMedia.isLive])
    case .stats:
        var snap = stats.snapshot()
        snap["music"] = music.snapshot()
        conn.respondJSON(snap)
    case .speedtest:
        stats.runSpeedTest()
        conn.respond(text: "ok")
    case .media:
        let cmd = p["cmd"] ?? ""
        if cmd == "open" { DispatchQueue.global().async { music.openPlayer() } } else { music.control(cmd) }
        conn.respond(text: "ok")
    case .artwork:
        guard let art = music.artwork() else { return conn.respond(404, text: "no artwork") }
        conn.respond(200, "image/jpeg", art)
    case .launcherRead, .launcherSave:
        // The same shared handler pattern as AppLaunchRoute: one entry point for GET and POST,
        // validation re-run inside, and no caller can reach the store without the check.
        LauncherRoute.handle(req, store: configStore, on: conn, shortcuts: shortcuts)
    case .icon:
        let path = p["path"] ?? ""
        guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
        DispatchQueue.main.async {
            let png = Apps.icon(path) ?? Data()
            server.queue.async { conn.respond(200, "image/png", png) }
        }
    case .shortcutRun, .shortcutStatus:
        ShortcutRoute.handle(req, registry: actions, service: shortcuts, on: conn)
    case .launch:
        // The same shared handler the integration tests exercise: it re-runs the M2.1
        // parameter check, then lets the registry authorize and dispatch.
        AppLaunchRoute.handle(req, registry: actions, on: conn)
    case .claude:
        let text = (p["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            if text.isEmpty { Claude.focus() } else { Claude.ask(text, autoSend: p["send"] == "1") }
        }
        conn.respond(text: "ok")
    case .cameraStream:
        cameraViewers.add(conn, latest: phoneMedia.latestFrame)
    case .cameraFrame:
        conn.respond(200, "image/jpeg", phoneMedia.latestFrame ?? Data())
    }
}
// Cleartext never serves the token-using deck script or a token-entry form.
// The HTTPS target comes from the native interface address, never Host/forwarded headers.
server.start(connectionAdmission: admission) { req, conn in
    if req.path == "/" || req.path == "/index.html" {
        return conn.respond(200, "text/html; charset=utf-8",
                            HTTPOnboarding.page(address: lanAddress(), httpsPort: opts.port + 2))
    }
    routes(req, conn)
}

// HTTPS + secure WebSocket for modern iPhones (Safari needs a secure page for camera, mic and speech).
let lanIP = lanAddress()
var httpsServer: HTTPServer?
if let identity = LocalTLS.identity(for: lanIP, existingOnly: opts.managedStartup) {
    do {
        let s = try HTTPServer(port: opts.port + 2, parameters: LocalTLS.parameters(identity), queue: server.queue,
                               budget: httpBudget)
        s.onListenerState = { startup?.observe($0, service: "HTTPS") }
        s.start(connectionAdmission: admission, routes)
        httpsServer = s
        phoneMedia.onListenerState = { startup?.observe($0, service: "WSS") }
        try phoneMedia.startWebSocket(port: opts.port + 3, identity: identity)
    } catch {
        if startup != nil { ManagedStartup.report("HTTPS/WSS listener creation failed"); exit(1) }
        print("⚠️  HTTPS failed to start: \(error)")
    }
} else if startup != nil { ManagedStartup.report("retained TLS identity could not be loaded"); exit(1) }

// MARK: Permissions + start

if !opts.managedStartup && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("⚠️  Grant Accessibility permission (System Settings → Privacy & Security → Accessibility) so Take note can press Return in Claude.")
}

print("""

OldPhoneDeck is running. On the phone (same Wi-Fi), open Safari and go to:

    https://\(lanIP):\(opts.port + 2)/#k=\(token)

Then tap Share → Add to Home Screen. Hold any key to choose your apps.

HTTPS is required for controls. Once, open http://\(lanIP):\(opts.port)/oldphonedeck.mobileconfig,
install it, enable it in Settings → General → About → Certificate Trust Settings,
then use https://\(lanIP):\(opts.port + 2)/#k=\(token)
Camera for OBS (Media Source): http://localhost:\(opts.port)/camera.mjpg?k=\(token)
Configuration directory: \(configDir.path)
Ctrl-C to quit.

""")

signal(SIGINT) { _ in exit(0) }
app.run()
