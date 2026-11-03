# ROADMAP.md — PhoneDeck milestones

Milestone status and scope. Only the current milestone is a mandate; everything below it
is direction, not approval. Steering defines each milestone as a bounded brief before it
starts (see `docs/STEERING.md` §7).

Legend: **COMPLETE** · **IN PROGRESS** · **NEXT** · **NOT STARTED**

---

## M0 — Baseline

**STATUS: COMPLETE** (2026-11-03)

Establish an untouched baseline of upstream `GLAUCOMA82/OldPhoneDeck` on this Mac and get
the original application running from the iPhone 11.

- Forked to `AdrianJTorres/OldPhoneDeck`; cloned to `~/Projects/PhoneDeck/OldPhoneDeck`.
- Remotes: `origin` = fork, `upstream` = parent; branch `main` at `e622184`, clean.
- `swift build -c release` succeeded with zero warnings; no source changes.
- Server running on `:8045` / `:8047` / `:8048`; iPhone 11 loaded the deck from the Home
  Screen and controlled the Mac (including Spotify).

## M1 — Understand & document

**STATUS: COMPLETE** (2026-11-03)

Understand the repository completely before modifying it, then record the result.

- **M1.1 — Repository analysis:** COMPLETE, accepted by Steering. Full architecture
  map, request flow, endpoint inventory, macOS integration list, persistence map,
  frontend analysis, extension points, risks (HIGH / MEDIUM / LOW).
- **M1.2 — Project documentation:** COMPLETE, reviewed and accepted by Steering. Delivered
  on `docs/project-steering`: `AGENTS.md`, `docs/STEERING.md`, `docs/ARCHITECTURE.md`,
  `docs/ROADMAP.md`, `docs/DECISIONS.md`. No product code changes.

Exit criteria: met — documentation accepted by Steering; no `Sources/**` or
`Package.swift` change; project builds.

## M2 — Foundations

**STATUS: IN PROGRESS**

M2.1 — Bounded HTTP Admission: **COMPLETE**, accepted by Steering. Implemented in
`4dd7fae593934053b5595b01cb52735351d42e18` on `m2.1/bounded-http-admission`: bounded
header/framing parsing, application-supplied early admission shared by HTTP/HTTPS, route
body limits, absolute header/body deadlines, and focused Swift Testing coverage.

Validation: independent Codex review returned **PASS** with no blockers, major findings,
minor findings or nits; 35/35 automated tests pass; the release build passes without
warnings; endpoint checks against the release binary passed, including HTTP/HTTPS admission
and a launcher save/read in temporary configuration. No physical iPhone acceptance is
claimed for this slice.

M2.2 — Bounded Media / Resources: **COMPLETE**, accepted by Steering (2026-11-03).
Implemented on `m2.2/bounded-media-resources` in `d0f665544b9d880e074825efbcdeeff65252d168`;
the framework-limit test correction is `6742816552590f46b80363cfe261f547aa820bee`.
Independent Codex review: PASS WITH MINOR FINDINGS, zero blockers/majors; its only
minor test-coverage finding was corrected and verified with a 2 MiB → 4 MiB mutation.
HTTP/HTTPS share 32 slots including up to two MJPEG viewers.
WebSocket ingress has two connection slots, a five-second authentication deadline from
readiness, one producer and bounded messages. Frame delivery coalesces to the latest
pending frame; proposed-total audio accounting caps playback at 4000 frames (250 ms).

Automated validation: all **63 Swift Testing tests** pass (35 retained M2.1 tests and
28 M2.2 tests, including parameterized close/rejection cases). The release build passes
without warnings. Loopback integration exercises the full 32-slot shared budget, all
HTTP close paths, MJPEG admission/drop/cleanup, pending WS handshakes, auth expiry,
producer exclusion, binary/control/message boundaries, and WSS-to-MJPEG delivery. The
WebSocket receive cap is now proven framework-only: a sink that performs no application
parsing rejects a 3 MiB message, so raising the production cap to 4 MiB fails those
checks. Real HTTPS/WSS use a temporary identity imported only into memory; no user
configuration, keychain certificates or audio hardware are touched. Tests do not start
the full app.

M2.3 — App Action Boundary: **IN PROGRESS** — implemented on `m2.3/app-action-boundary`
(`8097c28` implementation, `009e02d` test hardening), **pending independent review and
Steering acceptance**. Adds `Sources/oldphonedeck/ActionRegistry.swift`: a typed,
server-authoritative action boundary with a validated identifier, server-authored display
metadata, typed parameters, authorization inside the boundary and a controlled executor.
`app.launch` is the only registered action and unknown or malformed identifiers fail closed.
`POST /launch` is now a thin adapter that keeps its exact wire behaviour — `200 ok`,
`404 unknown app`, and the existing `403`/`405`/`411`/`413` admission — with `ok` still
meaning accepted-and-dispatched rather than activated. No new endpoint, no persistence, no
configuration schema, no token scope, no plugin loader and no UI change; `/media`,
`/claude`, `/speedtest`, `/launcher` and `/icon` remain legacy and are not migrated.

Validation: all **89 Swift Testing tests** pass (the 63 retained M2.1/M2.2 tests plus 26
new ones, four of them parameterized into 44 cases), covering action identity, parameters,
authorization, execution and `POST /launch` HTTP compatibility against a real loopback
listener. Tests inject a fake app catalog and a recording executor, so they never call
NSWorkspace or open an application. `swift build -c release` passes with no new warnings.
The release binary was exercised on isolated ports (8065/8067/8068) with rejection paths
only, so nothing launched, the two running personal instances were untouched and the real
configuration was not written. Four gate mutations — removing the catalog authorization,
removing parameter validation, removing the main-queue dispatch, and letting unknown
identifiers fall back to the registered action — were each observed to fail the relevant
tests and were reverted. No physical iPhone acceptance is claimed for this slice.

M2.4 — Configuration V1 codec: **NOT STARTED** and not mandated by M2.3. It is the next
candidate slice under ADR-007 and begins only on an explicit Steering brief.

M2 is **not complete**. The Action Registry now exists for app launch (M2.3, pending
review); versioned configuration has not started.
M5 remains the independent security/reliability review. Physical iPhone 11 checks passed
for WSS streaming, camera frames reaching the Mac, fresh-frame delivery, front/back
switching, reconnection and deck polling. Continuous live MJPEG was not confirmed on
the physical iPhone, although automated WSS-to-MJPEG delivery passed. Mic-to-Mac playback
was not verified because BlackHole was absent. Both limitations remain explicitly
unverified and must not be represented as acceptance passes; revisit in V1 device
acceptance when those capabilities are required.

Implement only the minimum architectural foundations required for safe extensibility.
Foundational boundaries — features must not be built ahead of them.

- **Action model / registry** — an internal representation of an approved action, with a
  server-side allowlist. No arbitrary shell execution, ever.
- **Versioned configuration** — a configuration format that can express controls, action
  types and metadata, with explicit migration that preserves the existing launcher
  selection.
- **Minimum ingress hardening** — request/body/header limits enforced *before* large
  buffering, basic connection and resource limits, and the minimum authorization boundary
  needed before higher-consequence actions.

Exit criteria: existing behaviour preserved on the iPhone 11; build clean; ADRs updated.

## M3 — PhoneDeck UI

**STATUS: NOT STARTED**

Turn the deck into the intended iPhone 11 control surface.

- iPhone 11 optimized control interface (layout, touch targets, always-on behaviour).
- **Data-driven controls** — keys and widgets described by configuration, not
  `APP_SLOTS` plus layout arithmetic.
- Media — now playing and transport as the primary interaction, not a footer.
- Mac status — network, batteries, and the Mac's own state.
- **Shortcuts** — run approved macOS Shortcuts from keys, through the action registry.

## M4 — Developer Deck

**STATUS: NOT STARTED**

Add developer surface, deliberately and narrowly.

- **Repo allowlist** — the Mac decides which repositories may be observed or acted on.
- **Git status** — branch, divergence, dirty state, recent commits, for allowlisted repos.
- **Run tests** — an approved action, not a command string from the browser.
- **Approved developer actions** — a fixed, auditable set.
- **Qwen / Codex status** — agent state where it is technically justified; introduced
  only together with the collector boundary.

## M5 — Security & reliability

**STATUS: NOT STARTED**

Independent review and hardening before V1.

- **Codex T3 independent review** of authentication, ingress, action authorization and
  process execution.
- **Auth** — complete assessment; resolve or explicitly accept the single-unscoped-token
  risk.
- **Ingress** — verify and complete the M2 limits; remaining timeouts, caps and edge cases.
- **HIGH risks** — resolve or explicitly accept what remains after M2.
- **Command boundaries** — prove no path from browser input to arbitrary execution.
- **Regression testing** — establish the missing test/CI baseline.
- **Reliability** — startup after reboot, IP change, TLS re-issue, failure visibility.

## M6 — PhoneDeck V1

**STATUS: NOT STARTED**

- Physical-device acceptance on the iPhone 11 against the V1 definition
  (`docs/STEERING.md` §8).
- Documentation completed and verified against the shipped behaviour.
- Clean installation and start procedure, from a fresh clone to a working Home Screen
  icon.

## Future — iPhone 7 Plus dashboard

Reserved, not scheduled, not a dependency of V1.

- Always-on information/dashboard role on the larger screen.
- Read-only telemetry focus rather than interactive control.
- Must not complicate the iPhone 11 primary path.
