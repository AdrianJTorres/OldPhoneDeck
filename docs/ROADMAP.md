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

M2.3 — App Action Boundary: **COMPLETE**, accepted by Steering (2026-11-06). Implemented on `m2.3/app-action-boundary`
(`8097c28` implementation, `009e02d` test hardening, `d83ae49` documentation, plus a
review-findings closure commit). Adds `Sources/oldphonedeck/ActionRegistry.swift`: a typed,
server-authoritative action boundary with a validated identifier, server-authored display
metadata, typed parameters, authorization inside the boundary and a controlled executor.
`app.launch` is the only registered action and unknown or malformed identifiers fail closed.
`POST /launch` is now a thin adapter that keeps its exact wire behaviour — `200 ok`,
`404 unknown app`, and the existing `403`/`405`/`411`/`413` admission — with `ok` still
meaning accepted-and-dispatched rather than activated. No new endpoint, no persistence, no
configuration schema, no token scope, no plugin loader and no UI change; `/media`,
`/claude`, `/speedtest`, `/launcher` and `/icon` remain legacy and are not migrated.

Independent Codex review: initial **PASS WITH MINOR FINDINGS** (zero blockers/majors,
three minor); focused independent re-review of correction commit `6d8cd813690e6d159562c8307c096fd8738023e9`
returned **PASS** (zero new findings). All three original findings were closed: `POST /launch` wiring was extracted into one
shared handler (`AppLaunchRoute.handle`) that production and the integration tests call
identically; the last test that held the real `Apps.launch` executor now injects a recording
callback, so no automated test can reach NSWorkspace even under an authorization regression;
and the inherited filesystem trust limits (exact path-string matching, symlinked catalog
entries, no object pinning, a TOCTOU window before the asynchronous launch) are recorded as
residual **M5** risk. Steering accepted M2.3 for integration after the independent
closure review. The residual filesystem risk remains open for M5.

Validation: all **90 Swift Testing tests** pass (the 63 retained M2.1/M2.2 tests plus 27
new ones, four of them parameterized into 44 cases), covering action identity, parameters,
authorization, execution and `POST /launch` HTTP compatibility against a real loopback
listener through the shared production handler. Tests inject a fake app catalog and a
recording executor, so they never call NSWorkspace or open an application.
`swift build -c release` passes with no new warnings. The release binary was exercised on
isolated ports (8065/8067/8068) with rejection paths only, so nothing launched, the two
running personal instances were untouched and the real configuration was not written. Gate
mutations — removing the catalog authorization, removing parameter validation, removing both
together, removing the main-queue dispatch, and letting unknown identifiers fall back to the
registered action — were each observed to fail the relevant tests and were reverted. No
physical iPhone acceptance is claimed for this slice.

M2.4 — Configuration V1 codec: **IN PROGRESS**. Implemented on
`m2.4/configuration-v1-codec` from Steering's approved design, recorded as **ADR-015**
(proposed), which elaborates ADR-007 without superseding it. Adds
`Sources/oldphonedeck/Configuration.swift`: a pure, **unwired** codec for a versioned
configuration document, plus in-memory legacy migration.

The V1 document is `{"version": 1, "controls": […]}`; the legacy launcher format stays a bare
JSON array, so the root type alone discriminates them. A control carries a stable opaque `id`,
an `ActionID`-validated `action`, flat `String → String` `parameters` and an optional bounded
`presentation.title`. `ConfigurationDecoder.decode` takes `ConfigurationInput`
(`.absent` / `.unreadable` / `.data`) and returns one of six distinguishable states — absent,
unreadable, legacy, V1, malformed and unsupported-version — replacing the single `nil` that
`Launcher.selected()` returns for three different situations. The version is identified before
any V1 structural or unknown-key check, so a newer document reads as newer rather than as a
pile of unknown keys; unknown keys are rejected; `version > 1` is unsupported rather than
malformed, and `version < 1` is malformed rather than "from the future". The encoder is as
strict as the decoder because it does not restate the decoder's rules: it serializes, then
requires its own output to decode back to the value it was given.

Reading is done by the codec's own strict RFC 8259 scanner rather than by `JSONSerialization`,
which accepts trailing commas, collapses duplicate names and widens every number to `Double`.
The scanner rejects a trailing comma, a repeated name at any level, trailing content after the
document, a raw control character inside a string, ill-formed UTF-8, a lone surrogate and
nesting deeper than 64; it keeps a number as its exact literal text, and `ExactJSONNumber`
decides integrality on those digits with no floating-point step, so `1.0000000000000001` is not
version 1 and `9007199254740993` is reported as itself. The 1 MiB cap is measured on the
canonical form — pretty-printed, sorted keys — in both directions, so a document is accepted
only if the bytes the codec would write back also fit.

`ConfigurationMigrator.migrateToV1` is purely syntactic — no `Apps.list()`, no filtering, no
sorting, no deduplication, no truncation — and preserves order, duplicates, empty strings and
an intentionally empty array; an entry that cannot be represented fails the whole migration
loudly instead of vanishing from it. Ids are positional (`app-1`, `app-2`, …) because a legacy
array may hold the same path twice. `legacySelection` is the **lossless** inverse rather than a
projection: it returns a selection only when migrating that selection back reproduces the
document exactly, so it also rejects any presentation title and any control id migration would
not have synthesized. An action that is syntactically valid but unregistered decodes with
inert `.unmodeled` parameters, which have no conversion to `ActionParameters`, so a document can
never make an action executable and authorization stays in `ActionRegistry.dispatch`.
`ConfigurationError` cases carry no payload from the document. Caps are 1 MiB and 4096
controls, and the byte cap bounds what can be stored rather than only what can be read.

**Not wired, and not accepted.** Nothing calls the codec: `Control.swift`, `ActionRegistry.swift`,
`main.swift`, HTTP routing, `web/index.html` and the real `~/.oldphonedeck/launcher.json` are
untouched, no endpoint changed, and runtime configuration behaviour is identical to M2.3. The
`ARCHITECTURE.md` §9 finding that absent and unparseable are indistinguishable therefore
remains **open** and closes only when M2.5 wires the codec into the read path. M2.4 stays
IN PROGRESS until the corrected codec passes independent re-review and Steering acceptance;
M2.5 (storage integration, read-path migration and any cutover) has not been briefed.

Validation so far: all **237 Swift Testing tests** pass (the 90 retained M2.1–M2.3 tests plus
147 new ones across 17 new suites, many parameterized), covering input states, legacy decode,
V1 decode, version precedence, document strictness and both caps, control identity, configured
actions, parameters, presentation, encoder strictness, round trips, migration, reverse
conversion, security invariants, strict JSON syntax, exact version parsing and the canonical
size invariant. Codec tests open no file and need no home-directory isolation; the
action-boundary checks reuse the injecting `testRegistry` helper, so no test constructs the
production `ActionRegistry()`. `swift build -c release` passes with no warnings.
Fourteen mutations — hoisting the unknown-key check above the version check, dropping empty
legacy entries during migration, making `legacySelection` skip unrepresentable controls,
collapsing `.unreadable` into `.absent`, removing the encoder's round-trip verification, making
`.unmodeled` convertible to `ActionParameters`, removing the control-count cap, removing the
losslessness guard from `legacySelection`, removing the duplicate-name rejection, tolerating a
trailing comma in an object or an array, removing the nesting-depth bound, admitting a raw
control character inside a string, reading the version through `Double` instead of its exact
literal text, and loosening the decoder's canonical size bound — were each observed to fail the
relevant tests and were reverted from a file backup rather than from git, leaving a working tree
verified byte-identical by SHA-256 after every restore. No physical iPhone 11 acceptance is
claimed or possible for this slice, because no endpoint or client behaviour changed.

Steering inspected the pushed implementation directly and found one deviation from the approved
brief: `legacySelection` was a partial projection, returning paths for controls whose title or
custom id it could not reproduce, and the test `aTitleDoesNotMakeAConversionLossy` approved that
loss. It has been corrected to the invariant
`migrateToV1(legacySelection(v1)!) == .success(v1)` for every non-nil result, that test was
replaced, and rejection of lossy titles, custom ids, reordered ids and gapped ids is now covered
alongside a round-trip invariant test that fails if every fixture is rejected. The V1 JSON
schema, and the encoder and decoder validation, are unchanged.

Independent Codex review of the pushed branch then found three further defects, all in how bytes
become values rather than in the schema. First, the version reached the codec already widened to
a `Double`: `1.0000000000000001` and `0.99999999999999999` read as version 1,
`9007199254740993` was reported to the user as `9007199254740992`, and `9223372036854775807` — a
legitimate future version — was reported as a corrupt file. Second, the 1 MiB cap was measured on
the document as read while the encoder writes a larger pretty-printed form, so a configuration
could be valid on disk and impossible to save unchanged. Third, reading went through
`JSONSerialization`, which accepts `{"version":1,"controls":[],}` and `["/a.app",]` and collapses
`{"version":2,"version":1}` to whichever copy it keeps, making the version depend on the reader
instead of on the bytes. All three are corrected in ADR-015 rules 6 and 7: a strict RFC 8259
scanner that keeps a number's exact literal text, `ExactJSONNumber` deciding integrality on those
digits with no floating-point step, and one canonical form shared by both directions with the cap
measured on it. Twenty-nine regression tests in three new suites cover the findings, and the
leniency tests assert both halves — that `JSONSerialization` still accepts the input and that the
codec does not — so reverting to a lenient reader fails loudly. The schema, the six-state model
and the migration rules are unchanged; what changed is which bytes are accepted. Sequences that
were never RFC 8259 documents are now malformed rather than silently read, and a document whose
canonical form exceeds the cap is now rejected rather than accepted as unsaveable. M2.4 remains
**IN PROGRESS** and ADR-015 remains **Proposed**: these corrections have not been re-reviewed or
accepted, and nothing is wired.

M2 is **not complete**. M2.1, M2.2 and M2.3 are accepted; the Action Registry currently
supports only app launch, and versioned configuration exists only as an unwired codec pending
independent review.
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
