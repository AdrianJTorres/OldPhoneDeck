# ARCHITECTURE.md — PhoneDeck

Architecture reference for coding agents. Describes **current behavior**, including
M2.1 bounded HTTP admission, and explicitly labelled **planned** extension seams.
The upstream baseline is `e622184`; M2.1 is not completion of M2 or the M5 review.

- Current behavior: §1–§8, §10–§11
- Known limitations: §12
- Planned extension seams: §13
- Risks: §9

Source of truth is the code. If this document and the code disagree, the code is right —
then fix this document.

---

## 1. System overview

One Swift process on the Mac. One HTML page in the phone's Safari. No client app, no
database, no external service.

```
 iPhone 11 (Safari, Home Screen)              Mac: single process `oldphonedeck`
 ┌───────────────────────────┐                ┌──────────────────────────────────────────┐
 │ index.html                │  HTTP  :8045   │ HTTPServer (Network.framework)           │
 │  · ES5 IIFE               │───────────────▶│  parse → routes closure → switch          │
 │  · inline CSS             │  HTTPS :8047   │                                          │
 │  · canvas / XHR / WS      │───────────────▶│  services (all long-lived, started once)  │
 │                           │  WSS   :8048   │   · Stats     1 s net, 60 s batteries     │
 │  camera ────────────────▶ │                │   · Music     2 s AppleScript poll        │
 │  mic    ────────────────▶ │                │   · PhoneMediaServer  JPEG in, PCM out    │
 └───────────────────────────┘                └──────────────────────────────────────────┘
        ▲   responses, MJPEG, JSON                        │
        └──────────────────────────────────────────────────┘
                                                          ▼
                                        macOS: NSWorkspace, AppleScript, CGEvent,
                                        IOKit, CoreAudio, /usr/bin shell-outs
```

Design consequences worth knowing:

- **Stateless request handling.** Every HTTP request is independent; there is no session,
  no cookie, no per-client state except the MJPEG viewer registry.
- **Push only for media.** The camera uses a long-lived MJPEG stream; everything else is
  polled by the client.
- **One shared serial queue** (`"http"`) serves both the HTTP and HTTPS listeners, so all
  request handling is serialised.
- **The Mac is authoritative** for what may be launched or executed.

## 2. Process architecture

`main.swift` is top-level code — no `@main`, no app delegate. It builds everything in
order and then blocks in `NSApplication.run()`:

1. `Options` parses `--port` (default `8045`) and `--mic-device` (default `BlackHole`).
2. `loadToken()` reads or creates `~/.oldphonedeck/token`.
3. `NSApplication.shared` with `.accessory` activation policy (no Dock icon, no menu bar).
4. `HTTPServer(port:)` binds the HTTP listener; failure here is fatal (`exit(1)`).
5. `PhoneMediaServer` + `AudioOut` are constructed; `AudioOut` may return `nil` if no
   matching audio device exists (warns, continues without mic playback).
6. `Stats().start()` and `Music().start()` begin their timers.
7. One application admission closure and the `routes` handler are handed to
   `server.start(admission:_:)`; HTTPS receives the same policy and handler.
8. `LocalTLS.identity(for:)` generates or loads the TLS identity; on success the HTTPS
   listener (`port + 2`) and the secure WebSocket listener (`port + 3`) start. **Failure
   is non-fatal** — the process continues HTTP-only with a printed warning.
9. Accessibility is checked (and prompted) once at startup.
10. `app.run()` blocks. SIGINT exits cleanly.

There is no graceful shutdown path, no persistence flush, and no supervision: run the
binary, stop it with Ctrl-C.

## 3. File and module map

| File | Lines | Responsibility | Key types / functions |
|---|---|---|---|
| `Package.swift` | — | One executable plus a Swift Testing target; copies `web/`, links AppKit | — |
| `main.swift` | — | Options, token, LAN address, application admission/route wiring, startup | `Options`, `loadToken`, `lanAddress`, `admission`, `routes` |
| `HTTPServer.swift` | — | Bounded receive/deadlines, one request per connection, responses, MJPEG | `HTTPConnection`, `HTTPServer` |
| `HTTPParsing.swift` | — | Incremental framing; application route metadata and admission | `HTTPRequestParser`, `HTTPRequestHead`, `HTTPRequest`, `HTTPFailure`, `DeckRoute` |
| `Tests/oldphonedeckTests/` | — | Swift Testing parser/admission and local socket tests; no app startup | `HTTPParsingTests`, `HTTPConnectionTests` |
| `TLS.swift` | 109 | Private CA, server cert, PKCS#12 identity, TLS/WS parameters | `LocalTLS.identity/makeCA/makeServerCert/loadIdentity/parameters` |
| `PhoneMedia.swift` | 153 | WSS ingest of camera/mic, latest-frame cache, audio playback | `PhoneMediaServer`, `AudioOut` |
| `Control.swift` | 116 | App enumeration/icons/launch, launcher config, Claude deep link, synthetic keys | `Input`, `Apps`, `Launcher`, `Claude` |
| `Music.swift` | 109 | Now-playing + transport via AppleScript, artwork fetch | `Music` |
| `Stats.swift` | 166 | Net throughput, speed test, batteries, `Process` helper | `Stats` |
| `web/index.html` | 797 | Entire UI: inline CSS, ES5 IIFE, layout, polling, WS client | `fit`, `layout`, `renderKeys`, `pollStats`, `wsOpen` |

Production module boundaries are **files, not separate library targets**: there is one
executable target and a dependent Swift Testing target; production types remain internal.
Treat the file split as the intended boundary anyway —
`HTTPServer` does not know about apps, `Music` does not know about HTTP.

## 4. Ports

| Port | Protocol | Purpose | Notes |
|---|---|---|---|
| `8045` (`--port`) | HTTP | Page, JSON API, MJPEG | Plaintext; token required except for the page and the iOS profile |
| `8047` (`--port + 2`) | HTTPS | Same route table over TLS | Only starts if a TLS identity was produced |
| `8048` (`--port + 3`) | WSS | Camera frames + mic audio | Token sent as the first binary message |

Clients derive the ports from the page they loaded: `https = port + 2`,
`wss = port + 3` (`index.html`).

## 5. Request flow

**Ingress (M2.1).** `NWListener` → `HTTPConnection.start` → bounded incremental
headers/framing → application-supplied admission → bounded body → handler. Header-phase
reads are at most 4 KiB and never exceed the remaining 16 KiB header allowance; admitted
body reads are at most 16 KiB and never exceed the remaining declared length. Coalesced
body bytes in the small header read are not retained until admission succeeds.

`HTTPServer` has no token knowledge. `DeckRoute` declares the supported method/path
pairs, public routes and body limits; `main.swift` uses that same enum in its exhaustive
handler switch. Both HTTP and HTTPS use `DeckRoute.admit` with the existing token.

Admission order:

1. Validate syntax and framing, including strict Content-Length, no Transfer-Encoding,
   and no Expect. Reject duplicate Content-Length, Content-Type or Host fields and
   duplicate decoded `k` query parameters.
2. Unknown path → `404`, with no body allowance.
3. Known protected path: query token must match, otherwise `403`, before body collection.
   A body token cannot authenticate or override this decision.
4. Unsupported method on a known public/authenticated path → `405`.
5. Body-bearing POSTs require Content-Length (`411`); excessive declared lengths → `413`.
6. Collect exactly the declared admitted body. Incomplete requests never invoke handlers.
   Decoded launch/Claude parameter checks run before their side effects.

**Limits:** request line 4 KiB (excluding CRLF), total headers 16 KiB (including request
line and CRLFCRLF), 64 header fields, individual header line 4 KiB (excluding CRLF).
Oversized request lines/targets return `414`, header bounds `431`, malformed framing
`400`, unsupported Expect `417`. Content-Length must be a single unsigned decimal
integer representable as Int; duplicate, signed, malformed and overflow values fail.

| Route | Maximum wire request body |
|---|---:|
| All supported GETs; POST `/speedtest` | 0 |
| POST `/media` | 1 KiB |
| POST `/launch` | 16 KiB; decoded path ≤4096 UTF-8 bytes |
| POST `/claude` | 64 KiB; decoded text ≤16 KiB; send absent, `0` or `1` |
| POST `/launcher` | 64 KiB |

The header absolute deadline is 10 seconds from connection acceptance, including TLS
setup. After headers are admitted, an incomplete body gets a fresh absolute 10 seconds.
Neither timer is extended by incoming bytes. Deadline expiry cancels the connection
without waiting for an error response to send. Timers stop before the normal handler;
response-send and stream timeouts remain deferred. Timers execute on the existing serial
HTTP queue, so queue stalls can delay cancellation; this is not a comprehensive DoS bound.

**Egress.** `respond()` writes a standard status reason, headers (`Cache-Control:
no-store`, `Connection: close`) and body, then cancels. One request per connection; no
keep-alive, chunk decoding or pipelining. Coalesced bytes beyond the declared body are
rejected; bytes arriving after dispatch are never interpreted as another request.

**Traces.**

- *Launch an app*: `POST /launch?k=…` `path=<app>` → `Apps.isKnown` → dispatch to the main
  thread → `NSWorkspace.openApplication` → `ok`.
- *Take note*: `POST /claude?k=…` `text=…&send=1` → dispatch to main → `claude://` deep
  link → after 2.0 s, if Claude is frontmost, `CGEvent` Return → `ok` returned immediately.
- *Dashboard*: `GET /stats` every 2 s → `Stats.snapshot()` (blocking `queue.sync`) merged
  with `Music.snapshot()` → JSON → client re-renders widgets.
- *Camera*: phone encodes JPEG at 15 fps → WSS `'V'` → latest-frame cache → fan-out to
  every `/camera.mjpg` viewer as `multipart/x-mixed-replace`.
- *Mic*: phone downsamples to 16 kHz mono s16le → WSS `'A'` → `AVAudioEngine` → output
  device (BlackHole by default).

## 6. Authentication flow

- A 12-character token is minted from a 31-character alphabet on first run and stored in
  `~/.oldphonedeck/token` (mode `0600`). Deleting the file rotates it.
- The deck URL carries `#k=<token>` in the **fragment**, which the browser does not send
  to the server; the client copies it to `localStorage` and appends `?k=<token>` to every
  API request.
- Every known protected API path is checked during header admission by a single
  string comparison against the query token, before body accumulation.
- The WebSocket requires the first message to be `'H'` + token, otherwise the connection
  is cancelled. Subsequent frames are trusted.
- Public exceptions: the page shell and the CA profile, so a Home Screen bookmark can load
  before a token is entered.
- The token is **unscoped**: it authorises every action the deck can perform.

## 7. Endpoint inventory

`Auth` = `?k=<token>` required. Public resources accept GET only; request body limits
apply before handlers (see §5).

| Method | Path | Auth | Purpose | Input | Output | Side effects |
|---|---|---|---|---|---|---|
| GET | `/oldphonedeck.mobileconfig` | — | iOS profile containing the CA | — | plist (`application/x-apple-aspen-config`) | none |
| GET | `/`, `/index.html` | — | Page shell | — | HTML (45,587 B) | bundle read |
| GET | `/info` | yes | Liveness / camera status | — | `{camera: bool}` | none |
| GET | `/stats` | yes | All widget data | — | `{net, speed, batteries, mac, music}` | none (blocks the HTTP queue briefly) |
| POST | `/speedtest` | yes | Run a speed test | — | `ok` | spawns `networkQuality` (~20 s) |
| POST | `/media` | yes | Transport control | `cmd` = `playpause`\|`next`\|`previous`\|`open` | `ok` | AppleScript to the player |
| GET | `/artwork` | yes | Album art | `id` (currently ignored) | JPEG or `404` | none |
| GET | `/launcher` | yes | App list + selection | — | `{selected: [path]\|null, all: [{name,path}]}` | directory scan |
| POST | `/launcher` | yes | Persist key selection | `paths` (newline-separated) | `{saved: n}` or `500` | writes `launcher.json`; unknown paths dropped |
| GET | `/icon` | yes | App icon | `path` | PNG or `404` | renders + caches on main thread |
| POST | `/launch` | yes | Open an app | `path` | `ok` or `404` | app activates |
| POST | `/claude` | yes | New Claude chat / focus | `text`, `send=1` | `ok` | opens `claude://`; may press Return |
| GET | `/camera.mjpg` | yes | MJPEG stream for OBS | — | `multipart/x-mixed-replace` | held open; registers a viewer |
| GET | `/camera.jpg` | yes | Latest frame | — | JPEG (may be empty) | none |
| — | `wss://host:<port+3>/` | handshake message | Camera + mic ingest | `'H'`+token, then `'V'`/`'A'` | none | updates frame cache; plays audio |

## 8. macOS integrations

**Frameworks:** AppKit, ApplicationServices (`AXIsProcessTrustedWithOptions`, `CGEvent`),
Network, Security (`SecPKCS12Import`, `sec_identity_create`), IOKit.ps, AVFoundation,
CoreAudio. Darwin `getifaddrs` / `getnameinfo`.

**Shell-outs** — fixed absolute binaries and fixed argv, never user-controlled:

| Command | Purpose | Cadence |
|---|---|---|
| `/usr/bin/networkQuality -c` | Download/upload/ping | Launch + on tap |
| `/usr/bin/osascript -e …` | Spotify / Apple Music state and transport | Every 2 s |
| `/usr/sbin/ioreg -r -k BatteryPercent -a` | Bluetooth HID batteries | Every 60 s |
| `/usr/sbin/system_profiler SPBluetoothDataType -json` | AirPods / case batteries | Every 60 s |
| `/usr/bin/openssl …` | CA and server certificate | First run, and on LAN IP change |

**AppleScript targets:** Spotify and Music — player state, current track metadata,
artwork, `playpause` / `next track` / `previous track`, `activate`.

**Permissions (TCC):** Accessibility (synthetic Return), Automation → Spotify / Music,
and on macOS 15 the Local Network prompt. On the phone: camera, microphone, speech
recognition, and trust for the OldPhoneDeck CA.

**External applications and schemes:** Claude desktop (`com.anthropic.claudefordesktop`,
`claude://`), Spotify, Apple Music, any app in the four scanned directories, BlackHole 2ch
(audio), OBS (consumer of `/camera.mjpg`).

## 9. Current security boundaries (and known risks)

**What the design does provide:** a token on every API call, an app-path allowlist before
launch or icon rendering (`Apps.isKnown`), re-filtering of config on save, no HTML
injection (dynamic text goes through `textContent`), no user-controlled argv in any
`Process`, fixed absolute binary paths, frame-drop backpressure on both media paths,
`0600` on the token and CA key.

**Open risks carried from M1.** Each risk is owned by a milestone, and ownership is not
interchangeable:

- **M2 — minimum foundational hardening.** Request/body/header limits enforced *before*
  large buffering, basic connection and resource limits, and the minimum
  action-authorization boundary that must exist before higher-consequence actions.
- **M5 — independent review and completion.** Codex T3 assessment of authentication,
  ingress, action authorization and process execution; remaining hardening; resolution or
  explicit acceptance of the remaining HIGH risks.

Nothing here is fixed opportunistically outside the milestone that owns it.

HIGH

| Risk | Where |
|---|---|
| Connection count remains uncapped — **M2.2**. M2.1 resolves the pre-auth large-body buffering component with bounded headers, early admission and route body limits. | `HTTPServer.swift`; no global connection budget yet |
| Cleartext HTTP carries the full-control token and all commands — **M5** | `:8045` route table |
| One unscoped token authorises every action; no expiry, scopes or audit — **M5** (M2 adds the minimum authorization boundary) | `DeckRoute.admit`, wired by `main.swift` |

MEDIUM

| Risk | Where |
|---|---|
| MJPEG viewers unbounded — **M2.2**; response/stream timeout tuning remains deferred. M2.1 adds header/body bounds and absolute receive deadlines; no keep-alive is intentional. | `HTTPServer.swift`, `main.swift` viewer registry |
| `server.key` and `server.p12` are `0644`; PKCS#12 password hardcoded; CA downloadable unauthenticated | `TLS.swift`, `/oldphonedeck.mobileconfig` |
| Configuration is a bare `[String]` with no version; unparseable and absent are indistinguishable | `Launcher.selected()` |
| Frontend geometry and `APP_SLOTS` are hardcoded | `index.html` `layout`, `renderKeys` |
| One serial queue serves both listeners; full app-directory rescan per icon/launch request | `HTTPServer.queue`, `Apps.list()` |
| Focused M2.1 Swift Testing suite only; broader regression/CI coverage remains absent | `Tests/oldphonedeckTests`, repository |
| Accessibility key press is time-based (fixed 2 s delay + frontmost check) | `Claude.ask` |
| TLS identity is re-issued only at startup, so an IP change degrades to HTTP-only | `LocalTLS.identity` |

Lower-severity findings (non-constant-time token comparison, `try?` swallowing token write
failures, AppleScript string interpolation, predictable temp artwork path, incomplete
status-reason map (statuses used by M2.1 are now covered), no auth logging, no Origin
checks, Swift 5 concurrency annotations)
are documented in the M1 analysis and remain open.

## 10. Local persistence and files outside the repo

Everything is under `~/.oldphonedeck`, plus one temp file:

| Path | Written by | Mode | Content |
|---|---|---|---|
| `token` | `loadToken` | `0600` | Access code |
| `launcher.json` | `Launcher.save` | `0644` | Ordered array of app paths (≤7), filtered to installed apps |
| `tls/ca.key` | `LocalTLS.makeCA` | `0600` | CA private key |
| `tls/ca.pem`, `ca.csr`, `ca.ext`, `ca.srl` | `LocalTLS.makeCA` | `0644` | CA material |
| `tls/oldphonedeck-ca.cer` | `LocalTLS.makeCA` | `0644` | DER served as the iOS profile |
| `tls/server.key`, `server.pem`, `server.csr`, `server.ext` | `LocalTLS.makeServerCert` | `0644` | Server cert, SAN = LAN IP + `127.0.0.1` + `localhost`, 800 days |
| `tls/server.p12` | `LocalTLS.makeServerCert` | `0644` | Identity bundle (hardcoded password) |
| `tls/server.ip` | `LocalTLS.makeServerCert` | `0644` | LAN IP stamp for re-issue |
| `$TMPDIR/oldphonedeck-art` | `Music.fetchArtwork` | — | Apple Music artwork relay |

In memory only: 60 s of network history, speed-test result, battery list, now-playing
snapshot, latest camera frame, MJPEG viewer registry, icon cache. Nothing is written
inside the repository at runtime.

## 11. Frontend architecture

One file. Inline CSS (~lines 16–240), markup, one IIFE of ES5.

- **Layout:** `#stage` is a fixed `480×320` design surface, absolutely positioned and
  scaled by a single CSS `transform: scale()` with origin `0 0`. `fit()` computes the
  scale from the viewport minus safe-area insets (measured via a hidden `env()` probe, so
  old iOS yields zero). Landscape `H = 320`, `W = clamp(480…760)`; portrait (modern only)
  `W = 360`, `H = max(520, …)`. `layout()` then places keys, music card and widgets with
  hardcoded pixel arithmetic per orientation.
- **State:** module-scope variables only, plus `localStorage` for `token` and `view`
  (wrapped in try/catch for private mode). App selection lives on the Mac, because
  Safari and the Home Screen app have separate storage.
- **Networking:** bare `XMLHttpRequest` wrapper (no `fetch`), form-encoded bodies, token
  in the query string. Polling: `/stats` every 2 s while the Deck view is visible; progress
  is extrapolated client-side every 1 s between polls.
- **Compatibility:** ES5 only, no `Promise`/`fetch`/`Intl`/template literals/`let`.
  `-webkit-` prefixes. Touch handling via `touchstart/move/end` with `preventDefault()`
  and a manual 550 ms long-press timer; no 300 ms click delay.
- **Modern-only features** are gated on `'isSecureContext' in window` (iOS ≥ 11.1):
  Deck/Phone segmented control, camera, mic, speech recognition, Battery API. Whether a
  feature is actually *usable* additionally requires `window.isSecureContext`, i.e. the
  HTTPS page.
- **Views:** `deck` (8 keys + now playing + Internet + Batteries), `phone` (camera/mic
  streaming), plus three sheets: Take note, app editor, token login.
- **Extension reality (today):** keys are 7 app slots plus one hardcoded "Take note" key;
  widgets are hardcoded cards whose geometry lives in `layout()`. Adding either means
  editing the layout arithmetic. This is what M3 changes.

## 12. Known architectural limitations

These are structural, not bugs to fix in passing:

1. No action abstraction — each verb is a `case` in one `switch`, so a new capability
   costs a new endpoint, a new client call and a new key type.
2. Configuration cannot express anything except "an ordered list of app paths".
3. No collector abstraction — `Stats` and `Music` happen to follow the same pattern, but
   `/stats` composes them by hand.
4. M2.1 bounds HTTP parsing and moves auth before bodies; connection/resource caps and
   the action boundary remain pending. One token still has one scope.
5. The frontend has no data model for controls; the layout is arithmetic.
6. Pure parser/admission logic and HTTP lifecycle have Swift Testing coverage. Other modules
   still lack isolated tests; there is no CI.

## 13. PLANNED extension seams

Approved direction (see `docs/DECISIONS.md` ADR-005 to ADR-010). Except for the
explicitly marked M2.1 HTTP admission portion, these seams are **not implemented**.

| Seam | Milestone | Shape |
|---|---|---|
| **Action boundary** | M2 (foundational) | An internal representation of an approved action — identifier, display metadata, validated parameters, server-side execution allowlist. App launch, Shortcuts, developer and Git actions all become implementations of it. No arbitrary shell execution. |
| **Versioned configuration** | M2 (foundational) | A versioned document under `~/.oldphonedeck` that can express controls, action types and metadata, with explicit migration that preserves the existing `launcher.json` selection. |
| **Ingress / auth hardening** | M2.1 HTTP admission implemented; remaining M2 → M5 | M2.1: bounded headers/body, early query-token auth, absolute receive deadlines. Pending: connection/resource bounds and Action authorization. M5: independent T3 assessment and remaining hardening. |
| **Collector boundary** | Just-in-time with M4 telemetry | Registry of collectors (each with its own queue) composed into one snapshot, so Git/agent status does not edit the route table. |
| **Frontend data model** | M3 | Data-driven controls and widgets, layout described rather than hand-computed — while staying one ES5 file with no framework. |

Deliberately **not** planned: a web framework, a database, keep-alive/HTTP2 work, a
rewrite of the transport layer, or a client app.
