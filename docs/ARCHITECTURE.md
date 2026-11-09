# ARCHITECTURE.md — PhoneDeck

Architecture reference including M3.2.1 on `m3.2/widgets-v2` (physical iPhone 11 acceptance PASS;
GitHub consolidation pending Steering acceptance).
The upstream baseline is `e622184`. M2.1–M2.4 and M2.5 S1–S7 are accepted by Steering;
**M2.5 is COMPLETE (2026-11-08)**. The V1/V2 codec (ADR-015/017), active `ConfigurationStore` and
revision-aware ES5 client (ADR-016/017) are wired end to end on this branch. Production remains
the accepted M3.1 release at `14872a3a`; this task does not deploy or migrate production.
`Launcher.selected()` / `Launcher.save()` are retired.

Steering confirms **PASS** for production migration/cutover, rollback rehearsal, production
authentication rotation and physical iPhone 11 acceptance. New authenticated access works on the
physical iPhone 11 and the previous token is rejected. Phase A is complete; these are recorded
acceptance results, not operations performed by the Phase B documentation consolidation.
M2.2 physical audio and continuous live MJPEG remain unverified; M2.5 does not close those gaps
or the M5 review.

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

1. `Options` parses `--port` (default `8045`), `--mic-device` (default `BlackHole`) and
   `--config-dir` (default `~/.oldphonedeck`). An explicit directory is resolved and created
   before services start; invalid or unusable values exit instead of falling back.
2. `LocalTLS` uses that directory; `ConfigurationStore(directory:)` is constructed without
   loading or migrating a file. `loadToken()` reads or creates its `token`.
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
| `HTTPParsing.swift` | — | Incremental framing; route metadata, admission and pure parameter validation, including launcher selection syntax | `HTTPRequestParser`, `HTTPRequestHead`, `HTTPRequest`, `HTTPFailure`, `DeckRoute` |
| `ResourceLimits.swift` | — | Explicit HTTP/media budgets, message validation, frame handoff, audio accounting | `HTTPConnectionBudget`, `MediaSessionBudget`, `PhoneMediaMessage`, `LatestFrameHandoff`, `AudioQueueBudget` |
| `ActionRegistry.swift` | — | Approved-action boundary: identifier syntax, server-authored metadata, typed parameters, authorization, controlled execution, shared `POST /launch` handler | `ActionID`, `ActionKind`, `ActionDescriptor`, `ActionParameters`, `AppLaunchParameters`, `ActionOutcome`, `ActionRegistry`, `AppLaunchExecutor`, `AppLaunchAdapter`, `AppLaunchRoute` |
| `Configuration.swift` | — | Pure V1/V2 codec and explicit latest-controls V1 export (ADR-015/017), used by the store: strict JSON, exact integers, shared canonical form, encode/decode and lossless in-memory migration. No file I/O, `Apps` or executor | `ControlID`, `ControlPresentation`, `ControlParameters`, `DeckControl`, `DeckConfigurationV1`, `ConfigurationError`, `ConfigurationInput`, `ConfigurationState`, `ConfigurationJSONValue`, `ConfigurationJSONScanner`, `ExactJSONNumber`, `ConfigurationCanonicalForm`, `ConfigurationDecoder`, `ConfigurationEncoder`, `ConfigurationMigrator` |
| `ConfigurationStore.swift` | — | Active storage (ADR-016): source precedence, bounded regular-file reads, revision, non-blocking lock, migration-on-read, atomic replacement, backup and recovery | `ConfigurationStore`, `ConfigurationStorePolicy`, `ConfigurationRead`, `ConfigurationRevision`, `ConfigurationFileOperations`, `POSIXConfigurationFile`, `ConfigurationWriteOutcome` |
| `LauncherRoute.swift` | — | Shared GET/POST handler, pure selection parser, response shape and refusal mapping; used by the application and loopback tests | `LauncherRoute.handle/parseSelection/responseJSON/refusal` |
| `Tests/oldphonedeckTests/` | — | Swift Testing parser/resource, action-boundary, configuration-codec, configuration-storage and HTTP/WS/WSS/TLS socket tests; no app startup | Parsing, lifecycle, budget, handoff, audio, action, launch-route, codec, store classification/revision/persistence/failure-injection and filesystem-platform tests |
| `TLS.swift` | — | Private CA, server cert, PKCS#12 identity, TLS/WS parameters | `LocalTLS.identity/makeCA/makeServerCert/loadIdentity/parameters` |
| `PhoneMedia.swift` | — | Bounded WSS ingest/lifecycle, latest-frame cache, audio playback | `PhoneMediaServer`, `MediaWebSocketConnection`, `AudioOut` |
| `Control.swift` | — | App enumeration/icons/launch, Claude deep link, synthetic keys; no selection persistence | `Input`, `Apps`, `Claude` |
| `Music.swift` | 109 | Now-playing + transport via AppleScript, artwork fetch | `Music` |
| `Stats.swift` | 166 | Net throughput, speed test, batteries, `Process` helper | `Stats` |
| `web/index.html` | — | Entire UI: inline CSS, ES5 IIFE, revision-aware configuration editor, layout, polling, WS client | `fit`, `layout`, `renderKeys`, `applyConfig`, `readConfig`, `saveError`, `pollStats`, `wsOpen` |

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

The client recovers the HTTP base port from the page: for HTTPS subtract 2 from the page port;
for HTTP use it directly. HTTPS is base + 2 and WSS is base + 3 (`index.html`).

## 5. Request flow

**Connection admission (M2.2).** Both listeners receive the same `HTTPConnectionBudget`
from `main.swift`: at most **32 active connections combined**, including incomplete
requests, responses and MJPEG streams. Acquisition precedes `HTTPConnection` construction
and connection/TLS startup. Excess connections are cancelled immediately; no `503` is
attempted because sending it would itself require starting/retaining another connection.
Each connection holds an idempotent lease. Normal send completion, parser rejection,
deadline expiry, transport errors and cancellation converge on one close method; it
cancels the transport, clears parser storage, releases the lease and calls `onClose` once.

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
   Decoded launch/Claude checks and POST `/launcher` selection syntax run through
   `DeckRoute.validateParameters` before side effects; shared handlers re-run validation.
   Launcher state and revision checks remain in the store under its lock (§7).

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

**MJPEG (M2.2).** After normal token admission, `MJPEGViewers` admits at most **2 viewers**
on the shared HTTP queue. Viewer #3 receives `503` and closes without replacing another
viewer. Each viewer also consumes one of the 32 HTTP slots. Close removes the registry
entry synchronously. A one-byte receive watches for peer EOF/error or unexpected further
input even when the camera is idle; any of those ends the stream. Only one JPEG send may
be in flight per viewer; new frames are dropped during that send.

The WebSocket-to-HTTP handoff stores one latest pending JPEG and schedules at most one
delivery block. A stalled HTTP queue cannot accumulate a block/data pair per incoming
frame. During delivery there can additionally be one executing frame; the frame cache and
each viewer's in-flight send remain separately bounded.

**Action boundary (M2.3, accepted).** `ActionRegistry` (`ActionRegistry.swift`) is the
only path from a caller to an approved macOS action. `ActionID` validates identifier syntax
(lowercase dotted name, at most 64 bytes) and the identifier must then name an entry in a
server-authored descriptor table; there is no registration entry point, so a client can name
an identifier but cannot add, rename or re-describe one, and an unknown or malformed
identifier fails closed. Descriptors carry a display name and a kind and never grant
authorization; they are not persisted. `ActionParameters` can only carry an application path
— data, never a command, argv element, script, environment variable or working directory.
Dispatch re-checks parameter well-formedness (non-empty, at most 4096 UTF-8 bytes, mirroring
the `/launch` wire limit) and then requires exact membership in the catalog `Apps.list()`
produced before `AppLaunchExecutor.schedule` performs the same `DispatchQueue.main.async`
hand-off to `Apps.launch` that the route used before M2.3. Authorization therefore happens
inside the boundary rather than in the route, so a caller that reaches the registry by any
route is still authorized. The catalog resolver and the execution callback are injected,
which is what makes the boundary testable without NSWorkspace. `POST /launch` is a thin
adapter, and the adapter is one shared handler — `AppLaunchRoute.handle` — called
identically by the production route switch and by the integration tests, so the tests cannot
pass against wiring production does not use. It re-runs the M2.1 parameter check, asks the
registry, and maps the outcome onto the historical response shape: the server names
`app.launch`, the client supplies only data, and every rejection keeps the historical
`404 unknown app`. `ok` still means accepted and dispatched, not activated. Only
`app.launch` is registered; every other route remains legacy.

**Traces.**

- *Launch an app*: `POST /launch?k=…` `path=<app>` → M2.1 admission → `DeckRoute.match` →
  `AppLaunchRoute.handle` (`DeckRoute.validateParameters` → `AppLaunchAdapter` →
  `ActionRegistry.dispatch(app.launch, appPath)` → parameter check → `Apps.isKnown`) →
  `AppLaunchExecutor.schedule` → main queue → `NSWorkspace.openApplication` → `ok`.
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
  the selected configuration directory's `token` (default `~/.oldphonedeck/token`, mode `0600`).
  Deleting the file rotates it.
- The deck URL carries `#k=<token>` in the **fragment**, which the browser does not send
  to the server; the client copies it to `localStorage` and appends `?k=<token>` to every
  API request.
- Every known protected API path is checked during header admission by a single
  string comparison against the query token, before body accumulation.
- WebSocket admission and message validation are described below; the token remains the
  same existing unscoped token, with no new authentication scheme.
- Public exceptions: the page shell and the CA profile, so a Home Screen bookmark can load
  before a token is entered.
- The token is **unscoped**: it authorises every action the deck can perform.

**Media resources (M2.2).** The private media queue owns all WebSocket slots, producer
state, receive callbacks, auth timers and cleanup. At most **2 connections**, including
pending handshakes and unauthenticated clients, are admitted before transport startup.
Overload cancels immediately. The first complete binary application message must be
`H` plus the exact UTF-8 token bytes, at most **256 bytes total**. Authentication must
finish within **5 seconds of `.ready`**; control traffic never extends this absolute
deadline. Failed auth, expiry, malformed messages, peer close, network failure and
cancellation remove the connection slot once. Successful auth cancels its timer.

Only **1 authenticated producer** may exist. Another valid authentication is rejected
without displacing the active producer. Pending connections reserve no producer slot;
closing the active producer releases it. A pre-ready handshake timeout and authenticated
idle timeout remain deferred; pending clients still consume the two-connection budget.

`NWProtocolWebSocket.Options.maximumMessageSize` is **2 MiB**. Only complete binary
application messages are accepted; text, unexpected continuation data and unknown
application types end the connection. Framework ping auto-reply stays enabled; ping/pong
are transport control traffic and cannot authenticate. A close frame ends the connection.

- `V`: at most **2 MiB minus one type byte**, with JPEG SOI/EOI envelope validation. The
  server relays bytes without image decoding; envelope validation is not full JPEG validation.
  Only the latest frame and its timestamp are cached; no producer-side frame queue exists.
- `A`: at most **8 KiB payload**, with an even byte count. Empty audio creates no work.
  Before allocating/converting PCM, `AudioQueueBudget` checks the proposed total against
  **4000 mono frames at 16 kHz (250 ms)**. A chunk that would exceed it is dropped whole,
  including an otherwise valid 8192-byte chunk (4096 frames). Reservations are returned
  on allocation failure or `.dataPlayedBack`, not early buffer consumption.

## 7. Endpoint inventory

`Auth` = `?k=<token>` required. Public resources accept GET only; request body limits
apply before handlers (see §5).

| Method | Path | Auth | Purpose | Input | Output | Side effects |
|---|---|---|---|---|---|---|
| GET | `/oldphonedeck.mobileconfig` | — | iOS profile containing the CA | — | plist (`application/x-apple-aspen-config`) | none |
| GET | `/`, `/index.html` | — | Page shell | — | HTML | bundle read |
| GET | `/info` | yes | Liveness / camera status | — | `{camera: bool}` | none |
| GET | `/stats` | yes | All widget data | — | `{net, speed, batteries, mac, music}` | none (blocks the HTTP queue briefly) |
| POST | `/speedtest` | yes | Run a speed test | — | `ok` | spawns `networkQuality` (~20 s) |
| POST | `/media` | yes | Transport control | `cmd` = `playpause`\|`next`\|`previous`\|`open` | `ok` | AppleScript to the player |
| GET | `/artwork` | yes | Album art | `id` (currently ignored) | JPEG or `404` | none |
| GET | `/launcher` | yes | Catalog, selection and configuration state | — | Shared launcher JSON (below), including widgets and degraded states | catalog scan; may migrate legacy/V1 data into V2 `config.json` |
| POST | `/launcher` | yes | Save selection/widget visibility with optimistic concurrency | `n`, `paths`, `expected`, optional paired `internet`/`batteries` | Shared launcher JSON + `saved`, or fixed error token | locked atomic write to `config.json`; retains one backup; never filters paths |
| GET | `/icon` | yes | App icon | `path` | PNG or `404` | renders + caches on main thread |
| POST | `/launch` | yes | Open an app through the action boundary | `path` | `ok` or `404` | app launch dispatched to the main queue (`ok` = accepted, not activated) |
| POST | `/claude` | yes | New Claude chat / focus | `text`, `send=1` | `ok` | opens `claude://`; may press Return |
| GET | `/camera.mjpg` | yes | MJPEG stream for OBS | — | `multipart/x-mixed-replace` | held open; registers a viewer |
| GET | `/camera.jpg` | yes | Latest frame | — | JPEG (may be empty) | none |
| — | `wss://host:<port+3>/` | handshake message | Camera + mic ingest | `'H'`+token, then `'V'`/`'A'` | none | updates frame cache; plays audio |

`POST /launch` remains the **only** route through `ActionRegistry`; its wire API is unchanged.
`/launcher` now uses `LauncherRoute.handle` and `ConfigurationStore`, which store data without
granting execution authority. `/media`, `/claude`, `/speedtest` and `/icon` remain outside the
registry; the other action-shaped capabilities require explicit later migration.

**Launcher response and request contract (ADR-016/017).** Authenticated GET returns `200` even in a
degraded configuration state. GET and successful POST always include `selected` (full path list or
`null`), `all` (the Mac's `{name,path}` catalog), `configuration` (fixed status token), `writable` and `widgets` (two booleans, or null when unknown).
`revision` is an opaque token, absent on `migrating`; `version` appears only for
`unsupported-version`. Successful POST adds `saved`, the number of stored entries, and supplies
the refreshed revision so another edit needs no GET. `[]` is an empty selection; `null` is not a
replacement deck and can also mean unconfigured or unprojectable data.

`configuration` values are `v1` (deferred V1 promotion), `v2`, `migrated`, `migrating`, `legacy-pending`, `unconfigured`,
`unrepresentable`, `too-many-controls`, `legacy-readonly`, `malformed`, `unsupported-version`,
`unreadable`, `wrong-format` and `corrupt` (`ConfigurationStatusToken`).

POST is form-encoded. Paired `internet`/`batteries` flags require exact `0`/`1`; both absent preserves
current preferences. With both present and neither `n` nor `paths`, only widgets change. All
updates use one revision over controls and flags, assembled under the lock.

Present `n` must be canonical unsigned decimal `0`–`7`; `n=0` requires empty
`paths`. For `n>=1`, split newline-separated `paths` preserving empties and require exactly `n`
entries, each at most 4096 UTF-8 bytes. Thus `n=1&paths=` stores one empty path. Absent `n` retains
legacy splitting that omits empty entries; store bounds still apply. `expected` echoes the last
revision. Refusal order is syntax/product bounds before I/O, lock acquisition, locked state
classification, missing/empty revision, then stale revision. Damaged data therefore reports its
state before a missing-revision refusal.

| HTTP status | Plain-text refusal token |
|---|---|
| `400` | `invalid-count`, `count-mismatch`, `entry-too-long`, `too-many-keys`, `missing-revision`, `invalid-widgets` |
| `409` | State token (for example `malformed`, `unrepresentable`, `too-many-controls`), or `stale` |
| `503` | `busy` (lock contention or inability to acquire a safe lock) |
| `500` | `write-failed`, `migration-failed`, `recovery-failed` |

Ingress/authentication failures retain §5's statuses. Error tokens contain no document content.

**Active store.** `main.swift` injects the selected configuration directory into the shared handler
for both HTTP and HTTPS. Every operation reclassifies disk state. `config.json` takes precedence;
only its absence allows `launcher.json` to be consulted, never its damage or unsupported version.
GET migrates decodable legacy/V1 data to V2 under a non-blocking exclusive lock, using the classification
re-read under that lock; the original `launcher.json` remains byte-intact. Contended migration
returns the legacy selection as `migrating`, read-only and without a revision.

Writes require a projectable, writable state and matching revision under the lock. They preserve
order, duplicates, empty entries and uninstalled paths. V1 migration copies full controls including metadata;
widget-only saves retain controls and app-only saves retain flags. Over-limit or unprojectable documents,
damaged/unsupported/wrong-format files and unrepresentable legacy data refuse writes. Projectable
over-limit data is served in full, never truncated on disk. A legacy array above the codec's
4096-control guard instead reports `malformed` with `selected: null`; its bytes remain untouched.

Commit prepares a `0600` same-directory temporary, writes and `fsync`s it, safely replaces
`config.json.prev` with the base generation, then atomically renames the new document into place.
Post-commit read/decode must equal the intended value. Failed verification restores the base bytes
captured under the lock, not an older backup. An initial migration has no base; failed verification
retains the damaged document and frozen legacy evidence and reports failure. Ordinary reads do not
automatically restore `.prev` or fall back to legacy data.

Before V1 promotion, an immutable byte-exact `config.json.v1` snapshot is prepared and verified;
`.prev` remains the rolling base. Unsafe/unpublishable snapshots block promotion. A valid V1
that cannot fit V2 remains untouched and read-only. Rollback uses the pure explicit
`ConfigurationMigrator.exportV1` on the latest V2, preserving all controls and intentionally
omitting flags; M3.1 cannot read V2 directly. No automatic downgrade or restore exists. See
ADR-017 for the separately authorized deployment and rollback procedure.

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
`claude://`), Spotify, Apple Music, any app in the five scanned directories, BlackHole 2ch
(audio), OBS (consumer of `/camera.mjpg`).

## 9. Current security boundaries (and known risks)

**What the design does provide:** a token on every API call, an app-path allowlist before
launch or icon rendering (`Apps.isKnown`), no HTML
injection (dynamic text goes through `textContent`), no user-controlled argv in any
`Process`, fixed absolute binary paths, frame-drop backpressure on both media paths,
`0600` on the token and CA key, and — since M2.3, accepted — one typed action
boundary that resolves a server-authored identifier, validates parameters and authorizes
against the Mac's own app catalog before a controlled executor runs. That boundary covers
app launch only; the other action-shaped routes still validate inline in the switch.

**Configuration boundary (M2.5, accepted and cut over to production).** Saving no longer applies
`Apps.isKnown`: preservation is not authorization (ADR-016 rule 11). Every launch still passes
the registry's fresh catalog check. Regular-file checks with `O_NOFOLLOW | O_NONBLOCK`, bounded
reads (1 MiB plus a detection byte), non-blocking advisory locking and locked revision comparison
protect the store's intended boundary; they do not defend against an arbitrary local writer.
Revisions fingerprint canonical content, so whitespace-only changes and lossless migration do not
invalidate a client. The 64-bit fingerprint is concurrency control, not authentication or integrity.

The M1 absent/unparseable configuration finding is **closed**: the shared
GET response distinguishes absence, damage, unsupported versions and read-only states, and the ES5
page displays a warning and blocks saves. S7 production migration/cutover is accepted by Steering.

**Open risks carried from M1.** Each risk is owned by a milestone, and ownership is not
interchangeable:

- **M2 — minimum foundational hardening.** Request/body/header limits enforced *before*
  large buffering, basic connection and resource limits, and the minimum
  action-authorization boundary that must exist before higher-consequence actions. M2.1 and
  M2.2 delivered the ingress and resource bounds; M2.3 (accepted after independent
  review and Steering acceptance) delivers the action-authorization boundary for app launch.
- **M5 — independent review and completion.** Codex T3 assessment of authentication,
  ingress, action authorization and process execution; remaining hardening; resolution or
  explicit acceptance of the remaining HIGH risks.

Nothing here is fixed opportunistically outside the milestone that owns it.

HIGH

| Risk | Where |
|---|---|
| M2.1/M2.2 bound HTTP bodies, connections, media clients and buffering. M2.2 passed independent review and targeted physical camera validation; physical audio and continuous live MJPEG remain unverified. These minimum bounds are not full DoS protection. | `HTTPServer.swift`, `ResourceLimits.swift`, `PhoneMedia.swift` |
| Cleartext HTTP carries the full-control token and all commands — **M5** | `:8045` route table |
| One unscoped token authorises every action; no expiry, scopes or audit — **M5**. M2.3 adds the minimum action-authorization boundary for app launch; the token itself still has one scope and authorises every legacy route. | `DeckRoute.admit`, `ActionRegistry`, wired by `main.swift` |

MEDIUM

| Risk | Where |
|---|---|
| Response-send, stalled-MJPEG-send, pre-ready WS handshake and authenticated WS idle timeouts remain deferred to **M5**. Resource counts are bounded; stalled clients can still occupy the available slots. | `HTTPServer.swift`, `PhoneMedia.swift` |
| `server.key` and `server.p12` are `0644`; PKCS#12 password hardcoded; CA downloadable unauthenticated | `TLS.swift`, `/oldphonedeck.mobileconfig` |
| Atomic visibility is not complete power-loss durability: file `fsync` is required, directory sync is best-effort, no `F_FULLFSYNC`. `.prev` retains only one generation; frozen legacy data cannot recover post-migration edits. A downgrade sees only the pre-migration selection. | `ConfigurationStore`, ADR-016 |
| Frontend geometry and `APP_SLOTS` are hardcoded | `index.html` `layout`, `renderKeys` |
| One serial queue serves both listeners; full app-directory rescan per icon/launch request | `HTTPServer.queue`, `Apps.list()` |
| Action authorization compares exact catalog path **strings** and pins no filesystem object. Catalog entries may be symlinks, and the target could change before the asynchronous launch (TOCTOU). Inherited unchanged from the pre-M2.3 route; no HTTP-only exploit identified. Resolution or acceptance is **M5** — see the M2.3 implementation note in `docs/DECISIONS.md`. | `Apps.list/isKnown/launch`, `ActionRegistry.dispatch` |
| Parser/resource, action, codec/store, HTTP and client logic have automated coverage; hardware audio playback and CI remain absent. S6 acceptance and S7 production cutover are accepted by Steering; hardware audio remains unverified. | `Tests/oldphonedeckTests`, repository |
| Accessibility key press is time-based (fixed 2 s delay + frontmost check) | `Claude.ask` |
| TLS identity is re-issued only at startup, so an IP change degrades to HTTP-only | `LocalTLS.identity` |

Lower-severity findings (non-constant-time token comparison, `try?` swallowing token write
failures, AppleScript string interpolation, predictable temp artwork path, no auth logging, no Origin
checks, Swift 5 concurrency annotations)
are documented in the M1 analysis and remain open.
The response reason map covers the statuses currently used, including `409 Conflict` added by S3.

## 10. Local persistence and files outside the repo

The default directory remains `~/.oldphonedeck`; `--config-dir PATH` redirects the token,
configuration/backup/lock/temporary files and TLS material together. It does not redirect the app
catalog. `~` and relative paths are resolved and standardized; missing, empty and flag-like values
are rejected. Newly created configuration directories are `0700`; existing directory modes are
preserved. The startup banner names the selected directory.

| Path | Written by | Mode | Content |
|---|---|---|---|
| `token` | `loadToken` | `0600` | Access code |
| `config.json` | `ConfigurationStore` migration/save/recovery | `0600` for store-created files | Authoritative V2 document after promotion (V1 remains readable); atomically replaced, never modified in place |
| `config.json.v1` | `ConfigurationStore` before first V1 promotion | `0600` | Immutable byte-exact pre-cutover V1 snapshot; no automatic restore |
| `config.json.prev` | `ConfigurationStore` backup swap | Source mode for hard link; `0600` for copy fallback | One base generation, prepared before commit; not auto-adopted on reads |
| `config.lock` | `ConfigurationStore` lock acquisition | `0600` | Regular, no-follow file; advisory `flock(LOCK_EX \| LOCK_NB)` held across migration/write/recovery |
| `launcher.json` | No writer in this branch | Existing mode retained | Frozen legacy array, read only when `config.json` is absent; never rewritten or deleted |
| `config.json.tmp-*`, `config.json.prev.tmp-*` | `ConfigurationStore` | `0600` | Exclusive random same-directory temporaries; operation-owned cleanup, no startup sweep |
| `tls/ca.key` | `LocalTLS.makeCA` | `0600` | CA private key |
| `tls/ca.pem`, `ca.csr`, `ca.ext`, `ca.srl` | `LocalTLS.makeCA` | `0644` | CA material |
| `tls/oldphonedeck-ca.cer` | `LocalTLS.makeCA` | `0644` | DER served as the iOS profile |
| `tls/server.key`, `server.pem`, `server.csr`, `server.ext` | `LocalTLS.makeServerCert` | `0644` | Server cert, SAN = LAN IP + `127.0.0.1` + `localhost`, 800 days |
| `tls/server.p12` | `LocalTLS.makeServerCert` | `0644` | Identity bundle (hardcoded password) |
| `tls/server.ip` | `LocalTLS.makeServerCert` | `0644` | LAN IP stamp for re-issue |
| `$TMPDIR/oldphonedeck-art` | `Music.fetchArtwork` | — | Apple Music artwork relay |

**Isolation (ADR-016 §12).** Use a fresh private directory and explicit `--config-dir`, copy TLS
material with modes preserved instead of sharing production paths, verify the certificate's LAN
IP, and let the isolated process mint its own token. The acceptance triple is 8055/8057/8058;
8057 is a separate browser origin from production 8047. Snapshot production hashes and metadata
beforehand and verify them at teardown; stop and remove only the owned instance and fixtures.
S4 completed that preparation/device/teardown sequence successfully. S6 acceptance and S7 production
cutover/rollback rehearsal are now accepted by Steering; this document performs none of those operations.

In memory only: 60 s of network history, speed-test result, battery list, now-playing
snapshot, latest camera frame, MJPEG viewer registry, icon cache. Nothing is written
inside the repository at runtime.

## 11. Frontend architecture

One file: inline CSS, markup and one ES5 IIFE. No framework or build step.

- **Layout:** `#stage` is a fixed `480×320` design surface, absolutely positioned and
  scaled by a single CSS `transform: scale()` with origin `0 0`. `fit()` computes the
  scale from the viewport minus safe-area insets (measured via a hidden `env()` probe, so
  old iOS yields zero). Landscape `H = 320`, `W = clamp(480…760)`; portrait (modern only)
  `W = 360`, `H = max(620, …)`. `layout()` then places keys, music card and widgets with
  hardcoded pixel arithmetic per orientation. M3.1 puts music above keys in portrait and beside
  them when landscape `W >= 640`; compact legacy landscape retains a single-row player.
  Transport targets are sized with the inverse stage scale to stay at least 44 CSS px effective.
  Featured metadata uses larger type and 52px artwork; titles/artists truncate within the card.
  Network/battery cards default to visible and can be hidden individually, with compact network styling and fewer battery rows when
  vertical space is limited. Media buttons expose labels, focus and Enter/Space activation.
  These changes are implemented on `m3.1/media-ui`; Steering reported physical iPhone 11 PASS
  on 2026-11-08 for Spotify controls, layouts, regression and Home Screen launch. Apple Music
  was not physically tested. M3.1 is accepted and merged at `14872a3a`; M3.2.1 physical iPhone 11 acceptance
  PASS was confirmed by Steering on 2026-11-09: six apps preserved, Save/Cancel, all four widget
  combinations, reload persistence, restoration of both widgets, Spotify/Claude/Phone regression,
  portrait/landscape and Home Screen. GitHub consolidation remains pending Steering acceptance.
- **State:** module-scope variables only, plus `localStorage` for `token` and `view`
  (wrapped in try/catch for private mode). App selection and widget visibility live on the Mac, because
  Safari and the Home Screen app have separate storage.
- **Configuration:** GET replaces `launcher` with the complete response (`selected` and `all`
  included). `applyConfig` tracks state, writable and revision, displays fixed text in `#cfgWarn`,
  and marks Save disabled. The save handler guards read-only states and sends `n`, encoded
  newline-separated `paths`, `expected` and both visibility flags. Internet/Batteries checkboxes
  draft changes until Save; Cancel/reopen restores saved values. A fixed ES5 descriptor list
  changes `display` only, retaining geometry and polling. Successful POST replaces the complete response and
  refreshes revision before another edit; it does not invent a selection from the local draft.
  Non-200 saves retain the draft and revision with feedback for stale/missing revision, busy,
  unreachable and failed-write states. Failed/malformed GET or malformed successful POST responses
  mark configuration unreachable and block saves while retaining the previous deck. Rendering may
  show only seven slots; read-only guards and the store prevent an over-limit/unprojectable deck
  from being overwritten by that display subset. M3.2.1 extends configuration/editor only;
  the accepted M3.1 geometry and existing execution paths remain unchanged.
  An already-loaded pre-M2.5 page omits `expected` and cannot save to the new server; reload before
  the first post-cutover edit. This compatibility refusal does not authorize production cutover.
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
  the two existing widgets have configured visibility and a fixed descriptor list; geometry stays
  in `layout()`. Broader ADR-010 data-driven controls/layout remain planned within M3.

## 12. Known architectural limitations

These are structural, not bugs to fix in passing:

1. One migrated action. `ActionRegistry` exists, but `app.launch` is its only registered
   action; every other verb is still a `case` in one `switch`, so a new capability costs a
   new endpoint, a new client call and a new key type until it is migrated onto the boundary.
2. V2 configuration and its store are active on this branch, but the ES5 editor still edits an ordered path list,
   not arbitrary controls, titles or custom ids. Unprojectable documents and selections above
   seven controls are read-only. Unknown actions remain inert; no new action capability is added.
   Frozen `launcher.json` is a compatibility/recovery artifact, not a second writable source.
   S7 production cutover is complete and accepted; migration-on-GET remains part of the store
   behavior. No further production operation is authorized by this documentation.
3. No collector abstraction — `Stats` and `Music` happen to follow the same pattern, but
   `/stats` composes them by hand.
4. M2.1 bounds HTTP parsing and moves auth before bodies; M2.2 bounds connection/media
   resources; M2.3 puts app launch behind an authorized action boundary (accepted).
   One token still has one scope, and the legacy action-shaped routes are not migrated.
5. The frontend has no data model for controls; the layout is arithmetic.
6. Parser/admission, HTTP/media lifecycle, resource accounting, media bounds, the action
   boundary, codec/store, launcher route and shipped client logic have Swift Testing coverage. Hardware playback and other
   modules lack isolated tests; there is no CI.

## 13. PLANNED extension seams

Approved direction (see `docs/DECISIONS.md` ADR-005 to ADR-010, and ADR-015 for the
configuration document shape and ADR-016 for storage). The M2.1 admission, M2.2 resource,
M2.3 app-action boundary, M2.4 codec and M2.5 S1–S4 storage/route/client portions are implemented.
Production cutover is complete; the remaining capabilities below are planned.

| Seam | Milestone | Shape |
|---|---|---|
| **Action boundary** | M2 (foundational) — `app.launch` implemented and accepted in M2.3 | An internal representation of an approved action — identifier, display metadata, validated parameters, server-side execution allowlist. `ActionRegistry` now carries this for app launch only; Shortcuts, developer and Git actions become implementations of it in later slices. No arbitrary shell execution. |
| **Versioned configuration** | M2.4 codec and M2.5 S1–S7 complete and accepted | V2 is implemented on this branch through `ConfigurationStore` and the shared launcher handler (ADR-017), physical iPhone 11 acceptance PASS (2026-11-09), GitHub consolidation pending Steering acceptance; production remains M3.1/V1. Source-aware migration preserves frozen legacy bytes; canonical revisions, locking, atomic replacement, backup and verified recovery protect edits. The ES5 client consumes state and refreshed revisions but remains a seven-slot path-list editor. Decoding or storing a path confers no execution authority. See §7 and §10; S7 production cutover is accepted. |
| **Ingress / auth hardening** | M2.1 admission and M2.2 resource bounds implemented; remaining M2 → M5 | Bounded headers/body, early query-token auth, receive/auth deadlines, connection/media caps and bounded frame/audio buffering. M2.2 passed independent review and Steering acceptance. Action authorization exists for app launch (M2.3, accepted); the remaining routes and the unscoped token belong to M5's independent T3 assessment and hardening. |
| **Collector boundary** | Just-in-time with M4 telemetry | Registry of collectors (each with its own queue) composed into one snapshot, so Git/agent status does not edit the route table. |
| **Frontend data model** | M3 | Data-driven controls and widgets, layout described rather than hand-computed — while staying one ES5 file with no framework. |

Deliberately **not** planned: a web framework, a database, keep-alive/HTTP2 work, a
rewrite of the transport layer, or a client app.

### M3.3 — Approved UUID Shortcuts (2026-11-09)

ADR-018 adds `Shortcuts.swift`: private operator-owned approvals, a strictly typed UUID,
current catalogue verification, one shared execution slot and asynchronous Foundation
Process lifetime management. `ActionRegistry` resolves `shortcut.run` and delegates its
server-owned authorization/execution policy to the shared `ShortcutService`. The only
executable is `/usr/bin/shortcuts`, with fixed `list --show-identifiers` or `run UUID`
arguments. There is no shell or HTTP approval/registration API. Empty approvals are default.

Authenticated POST/GET `/shortcut` reuse `DeckRoute` admission and shared HTTP/HTTPS resource
limits. POST body cap: 1 KiB; GET: zero. POST returns a run ID immediately. GET reports
only the latest run. Availability lookup is bounded to five seconds; run deadline is 30
seconds. Nonblocking drainage retains at most 64 KiB stdout and discards stderr. Timeout
publishes an unknown side-effect outcome, terminates the CLI and escalates after 500 ms;
the slot closes only after process exit/descriptor cleanup. Apple's external engine is
outside that process lifetime guarantee. CLI exit 0 is completion evidence only.

`/launcher` adds full ordered controls, `controlsWritable` and approved-only Shortcut metadata.
Complete-control POSTs reuse V2 strict decoding, locking, revision, commit verification and
recovery; they preserve IDs, order, titles, unknown parameters and widgets. Legacy app-path
POSTs refuse mixed/metadata documents. `selected` and `writable` retain legacy meanings.
The ES5 editor uses complete controls and preserves unavailable entries in their positions.
Seven app selections remain untouched until an explicit Save replaces them. No configuration
load, save, approval load, build or test executes a real Shortcut. Operator/consent details:
`M3.3-SHORTCUTS.md`. Physical iPhone 11/server-context execution and Steering acceptance are
PENDING; production remains untouched.
