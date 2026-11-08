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

**STATUS: COMPLETE** — accepted by Steering (2026-11-08).

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

M2.4 — Configuration V1 codec: **COMPLETE**. Accepted by Steering on 2026-11-06 after the final
independent Codex review returned **PASS** with no unresolved major or minor findings. Implemented
on `m2.4/configuration-v1-codec` from Steering's approved design, recorded as **ADR-015**
(accepted), which elaborates ADR-007 without superseding it. Adds
`Sources/oldphonedeck/Configuration.swift`: a pure codec delivered **unwired at M2.4**, plus
in-memory legacy migration (subsequently wired by M2.5 S3). M2.4 acceptance covers the codec, its tests
and its documentation only; **no physical-device acceptance is claimed**, because no endpoint,
route or client behaviour changed and there was nothing on a device to exercise.

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

**M2.4 delivery history.** Steering accepted the codec without route/client wiring or runtime
migration; the legacy `Launcher` was still active then. M2.5 S3 later wired the read path, closing
the absent/unparseable finding in the implemented branch, and S4 added the revised client. That
later implementation and the accepted production migration/cutover are recorded below.

Validation at acceptance: all **248 Swift Testing tests** pass (the 90 retained M2.1–M2.3 tests plus
158 new ones across 17 new suites, many parameterized), covering input states, legacy decode,
V1 decode, version precedence, document strictness and both caps, control identity, configured
actions, parameters, presentation, encoder strictness, round trips, migration, reverse
conversion, security invariants, strict JSON syntax, exact version parsing and the canonical
size invariant. Duplicate names are detected with a set local to each object, so a wide object
costs a lookup per name rather than a scan of the names already seen; the scanner runs before any
schema bound, so that path is limited only by the document cap. Codec tests open no file and need
no home-directory isolation; the action-boundary checks reuse the injecting `testRegistry`
helper, so no test constructs the production `ActionRegistry()`. `swift build -c release` passes
with no warnings.
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
canonical form exceeds the cap is now rejected rather than accepted as unsaveable. At the time
these corrections had not been re-reviewed; the re-review that followed is recorded next.

Re-review returned **FAIL** on one remaining major defect, in `ExactJSONNumber.exactInteger`. The
exponent accumulator stopped updating past a fixed magnitude of 1 000 000 and then carried the
frozen value into `exponent − fractionCount` as though it were exact. Because the freeze point was
a constant while the fraction length is bounded only by the document, a huge exponent could cancel
a huge fraction: `0.` + 999 999 zeros + `1e10000000`, which is exactly 10^9000000, decoded as
**version 1**, and `1` + 1 000 000 zeros + `e-10000000`, which is exactly 10^-9000000 and not an
integer at all, also decoded as version 1. Both documents fit inside the 1 MiB cap, so nothing
else rejected them. Corrected by deriving the bound instead of choosing one: with `m` mantissa
digits and `f` after the point, a nonzero value needs `E − f ≤ 18` to fit `Int.max < 10^19` and
needs `f − E < m` to be an integer, so every exponent outside `±(m + 19)` is provably out of range.
Past that bound the value is discarded rather than truncated, and the token is decided by its
mantissa alone — nil if nonzero, `0` if zero. Seven tests cover the two reproductions, the derived
bound, exponents a million digits long, long runs of leading zeros, and zero under an absurd
exponent; two of them assert that a large mantissa and a large exponent which genuinely cancel
still read as exactly 1, so rejecting every large exponent cannot pass. The scanner, the schema,
the decoder states and the canonical size contract are unchanged.

A final independent Codex review of `ad46842` returned **PASS** on 2026-11-06 with no unresolved
major or minor findings, and Steering accepted M2.4 and ratified ADR-015 the same day. The four
defects recorded above are **closed**; they are retained here as historical evidence of what the
review process caught, not as open findings.

**Acceptance evidence.**

- **248 Swift Testing tests in 29 suites pass**, with no recorded issues, no errors and no
  compiler warnings — the 90 retained M2.1–M2.3 tests plus 158 new ones in 17 new suites.
- **`swift build -c release` completes with zero warnings** from a clean tree.
- **Exact numeric parsing verified**: literals that widen to the same `Double` are distinguished,
  `1.0000000000000001` and `0.99999999999999999` are not version 1, `9007199254740993` is reported
  as itself, `Int.max` reads as a newer version rather than as corruption, one past it is
  malformed, and exponents large enough to cancel a million-digit fraction are decided by a bound
  derived from the mantissa length.
- **Strict JSON validated**: trailing commas, duplicate names, trailing content, raw control
  characters, ill-formed UTF-8, lone surrogates and nesting past 64 are each rejected, and every
  divergence test asserts both halves — that `JSONSerialization` still accepts the input and that
  the codec does not.
- **Canonical-size invariant validated**: a document that fits the cap as read and overflows it
  once written is rejected, and everything the decoder accepts is proven writable back inside the
  same cap through the one shared canonical form.
- **Duplicate-name performance corrected**: detection moved from a per-name linear scan to a set
  local to each object, removing an O(n²) path the scanner reached before any schema bound. A
  90 000-member object near the document cap went from not completing within six minutes to
  0.77 s, while a large mantissa and a large exponent that genuinely cancel still read as exactly 1.
- **Lossless legacy migration validated** by `migrateToV1(legacySelection(v1)!) == .success(v1)`
  for every non-nil result, and by a positive table that cannot pass by rejecting every fixture.
  Order, duplicates, empty strings and an intentionally empty array are all preserved.
- Fifteen mutations across the three review rounds were each observed red and reverted from file
  backups verified byte-identical by SHA-256; `git checkout` and `git reset` were never used
  against uncommitted work.
- **No physical-device acceptance is claimed** for M2.4, and none was possible: no endpoint, route
  or client behaviour changed, so there was nothing on the iPhone 11 to exercise.

**Nonblocking documentation debt.** `AGENTS.md` §2 (Source layout) has no `Configuration.swift`
row. That file is protected against agent edits in this workflow, so the row could not be added
across any of the four M2.4 commits; it is recorded here for a human edit. It does not block
acceptance, because `docs/ARCHITECTURE.md` §3 (File and module map) carries the equivalent row and
lists the codec's exported types.

M2.5 — Storage Integration & Migration Cutover: **COMPLETE** (2026-11-08). Design approved by Steering and
recorded as **ADR-016** (accepted 2026-11-07), which elaborates ADR-007 and ADR-015 without
superseding either. The consolidated design is `docs/M2.5-DESIGN.md`; the drafting record is
`docs/M2.5-ADR-016-DRAFT.md`. The milestone is split into slices S1, S1b, S2–S7 (§13 of the design);
**S1, S1b and S2–S4 are implemented and ACCEPTED by Steering** on
`m2.5/s1-configuration-store`, S2 including its security correction (0700 for newly created
configuration directories, flag-like `--config-dir` values rejected). **S3 — the runtime wiring of
`GET`/`POST /launcher` to `ConfigurationStore`, retiring `Launcher.selected()`/`Launcher.save()`
and the `Apps.isKnown` save filter, and adding `409` to the reason map — is accepted** after the
independent review (373/373 tests, no blockers). **S4 is implemented by Codex**, reassigned as
the sole WRITE_OWNER by Steering: the ES5 page consumes the full GET/POST shape, sends
`n`/`paths`/`expected`, refreshes its revision after a save, and blocks saves in read-only states
with a visible warning. Stale, busy, unreachable and failed-write responses retain the edit and
show an explanation. The accepted S3 minor is also closed: `DeckRoute.validateParameters` reuses
the pure selection parser; missing-revision and state refusals stay in the store in their existing
order. **S4 physical iPhone 11 acceptance PASS**, confirmed by the user: keys and icons, changing
and saving a key, a second save without reload, persistence after reload, portrait/landscape and
Home Screen behavior. **S1–S7 are ACCEPTED by Steering**, including S5 documentation,
S6 isolated acceptance and S7 production cutover. Phase A is complete.

S4 automated evidence: **52/52 focused tests** in four suites and **388/388 full-suite tests** in
41 suites pass with the documented CLT Testing framework. JavaScriptCore executes the shipped
keys/editor code, including a real loopback GET → edit → POST → edit → POST against a temporary
store, stale-write feedback and an over-limit save guard. The entire inline script parses as
ECMAScript 5; the layout, tap, key-rendering and editor-interaction functions match S3. A clean
release build passes with zero warnings. Tests deny access to the real configuration directory;
no production server was started or stopped. These checks do not replace physical iPhone evidence.

S4 isolated device staging (historical, before S7) verified migration-on-GET, HTTPS using a
mode-preserving copy of the existing TLS material, matching LAN-IP certificate coverage, and three
fixture-app PNG icons on 8055/8057/8058. The isolated process used a temporary configuration directory and fresh token;
access to production configuration was denied for that process. **Teardown PASS**: only the owned
isolated instance was stopped, the verified fixture directory and logs were removed, and all 16
production entries matched baseline SHA-256, permissions and modification/change timestamps.
Production listener inventory was unchanged and Git remained clean at `d0d8747`. No production
files were migrated, no production process was stopped/restarted, and no cutover occurred.

**Closure evidence — Steering confirmation (2026-11-08).** The following production and device
results are recorded from Steering's confirmation; Phase B does not rerun these operations.

- **S7 production cutover / migration: PASS.**
- **Rollback rehearsal: PASS.**
- **Production authentication rotation: PASS.** New authenticated access works on the physical
  iPhone 11; the previous token is rejected. No credential values or authenticated URLs are recorded.
- **Physical iPhone 11 acceptance: PASS.**

M2.5 consolidation was merged through PR #6. M2 was subsequently accepted as complete by
Steering before authorizing M3.1.

**S1 delivery record (historical).** S1 added `Sources/oldphonedeck/ConfigurationStore.swift`
without wiring it into the application. At that slice the legacy `Launcher` remained active,
`Configuration.swift` was unchanged and no endpoint/client behavior or real configuration was
modified. S3 subsequently activated the store and S4 activated the revised client on the feature
branch. The store accepts an injected directory because `NSHomeDirectory()` ignores `$HOME` on
this macOS build; automated store tests use temporary directories.

What S1 implements: source-aware classification into ten distinguishable states, replacing the
single `nil` the former `Launcher.selected()` returned for three different situations; bounded reads with
`O_NOFOLLOW | O_NONBLOCK`, an `fstat` regular-file check and a cap-plus-one byte limit, so a symlink
fails closed, a FIFO cannot block the shared HTTP queue and an oversized file is never fully
allocated; an opaque revision token fingerprinting the canonical V1 *content*, so neither a
whitespace-only hand edit nor a lossless migration invalidates a client; non-blocking `flock` on a
separate `config.lock` held across the whole read-modify-write including a migration-on-read that is
double-checked under the lock; the three-phase commit with the backup prepared under a temporary name
and swapped in **before** the commit; recovery from the base bytes captured under the lock rather
than from the backup; and a per-step filesystem seam that makes every failure point injectable.

Validation at S1: all **319 Swift Testing tests pass in 36 suites** (the 248 retained M2.1–M2.4
tests plus 71 new ones in 7 new suites), covering classification and source-awareness, symlinks,
FIFOs, directories and unreadable files, the revision lifecycle including migration transparency,
over-limit read-only behaviour, selection preservation for empty, leading, trailing and duplicate
paths, ten failure injections with byte-level assertions on both generations, a two-queue
concurrency storm, and the platform measurements ADR-016 rule 8 requires. `swift build -c release`
passes with **zero warnings**. **Eight gate mutations** — removing the seven-control writable gate,
moving the backup swap after the commit, dropping the in-lock migration re-check, skipping
post-commit verification, dropping `O_NOFOLLOW`, fingerprinting raw bytes instead of canonical
content, accepting a missing revision, and accepting a stale revision — were each observed to turn
the relevant tests red and were reverted from a backup verified byte-identical by SHA-256. One
mutation in the first round was ineffective rather than caught: it removed a comparison that an
earlier `guard let` already made unreachable, and was replaced by one that removes the gate where it
actually is. **No physical iPhone 11 acceptance is claimed or possible for S1**, because no endpoint
or client behaviour changed.

Two findings surfaced while implementing S1, recorded rather than worked around, because working
around either would mean changing `Configuration.swift` or adding a second parser:

- A legacy array with more entries than `ConfigurationDecoder.maximumControlCount` (4096) is
  rejected by the codec's corruption guard **before** migration can run, so it reports `malformed`
  with `selected: null` rather than `legacy-readonly` with its selection served. ADR-016 rule 3's
  promise therefore holds only for legacy files the decoder accepts. The reachable shapes of
  `legacyUnrepresentable` are an entry longer than 4096 bytes and a canonical form over 1 MiB.
- A legacy file with more than seven entries migrates faithfully and lands in the over-limit state,
  so it becomes read-only immediately after migration. That is rule 11 working as intended, but it
  means a hand-edited legacy selection above seven keys can be seen and used, and not edited, until
  it is reduced by hand.

The shared `LauncherRoute.handle` and `DeckRoute.validateParameters` selection checks now resolve
the former S1b/S3 structural blockers recorded in `docs/M2.5-DESIGN.md` §17. State and revision
refusals remain in the store in the approved order. The accepted compatibility limitation remains:
an already-loaded pre-M2.5 page can read but cannot save to the new server without `expected`;
reload the revised page before the first post-cutover save.

M2 overall is **COMPLETE**, accepted by Steering on 2026-11-08. M2.1–M2.4 and M2.5 S1–S7
are accepted; the Action Registry supports app launch, and versioned configuration is wired end
to end with accepted production cutover (store, route, wire contract and client).
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

**STATUS: IN PROGRESS**

**M3.1 — Media-first iPhone UI:** implementation accepted by Steering after physical iPhone 11
validation PASS (2026-11-08); GitHub consolidation is pending integration review. Implemented in
`bd73790b9c00b6322b042b89fdff16a0efe58490` on `m3.1/media-ui`.
The existing music card leads the portrait deck and sits
beside the keys in wide landscape. Larger metadata, artwork and transport controls reuse
`/stats`, `/artwork` and `/media`; effective transport targets are at least 44 CSS px after stage
scaling. App keys, Claude, connectivity, network and battery status remain available. Compact
legacy landscape retains its single-row player. No backend, endpoints, configuration format,
dependencies or action types change. ADR-010's broader data-driven frontend remains later M3 work.

Automated verification: the full inline script parses as ES5; 25 focused client/launcher HTTP
checks pass; a clean release build completes with zero warnings. Browser checks at five viewport
sizes cover portrait/landscape with simulated safe areas and Safari chrome, plus 480×320 compact
layout: transport targets measure at least 44 CSS px, cards do not overlap or leave the viewport,
and eight keys remain. Mocked transport commands, empty player and disconnected status pass.
Isolated HTTP/HTTPS preview serves the shipped resource and a copied V1 configuration, with
production access denied by a process sandbox; production contents and metadata remain unchanged.
Browser emulation and automated checks do not establish physical Safari acceptance.

Physical acceptance evidence, reported by Steering on 2026-11-08: **iPhone 11 PASS** for Spotify
playback controls, portrait layout, landscape layout, Apps/Claude/status regression and Home Screen
launch. **Apple Music was not physically tested**; no physical acceptance is claimed for it.
The automated results above are retained from the implementation record; broad tests were not
rerun for this documentation consolidation. No additional physical checks are inferred.

Current integration status: the accepted implementation is being consolidated for one PR from
`m3.1/media-ui` to `main`, pending Steering review. Merge and production deployment are not
authorized by this consolidation. The existing production server is left running. M3 overall
remains **IN PROGRESS**; later M3 work is not authorized by this acceptance.

**M3.2.1 — Configurable Widgets V2: IN PROGRESS, implementation pending acceptance.**
Architecture approved by Steering on 2026-11-08 (ADR-017); based on approved M3.1 merge
`14872a3a`, branch `m3.2/widgets-v2`, Codex WRITE_OWNER. Two fixed Internet/Batteries
visibility flags persist through the existing revision-aware store and ES5 Save/Cancel editor.
V1 controls and metadata migrate intact; immutable V1 snapshot and explicit latest-controls
V1 export support a separately authorized rollback. No production configuration/token/TLS/server
is touched, no deployment or merge is authorized, and M3.1 production remains accepted.

Automated validation: **405 Swift Testing tests in 43 suites PASS**, including V2 codec/migration,
metadata preservation, four combinations, paired-field refusals, stale/mixed concurrent writes,
failed-write recovery, snapshot retention and latest-controls V1 export. Release build passes with
zero warnings. The complete inline script parses as ES5 with the existing Node-bundled Acorn;
real browser checks against isolated HTTPS pass long-press, Save/Cancel, all four combinations,
reload and six unchanged controls. Five viewport cases retain geometry, eight keys and effective
media targets ≥44 CSS px; app/media callbacks were intercepted before reaching the Mac.
An isolated M3.1 binary refuses V2 and serves all six latest selections after explicit restoration
of the actual pure exporter output. No automatic downgrade or production material is used.
The independent review identified a visibility-only save from writable `legacy-pending` that
could discard the six pending legacy selections after a transient GET migration failure. The
owner fixed preservation of the pending document and added a real HTTP GET/failure/POST
regression; the 405-test result above includes it.
One independent focused review of codec/store/wire integrity and rollback is requested on the
implementation commit before Steering acceptance; its result remains pending here. Physical iPhone 11
acceptance remains pending: all four combinations and re-enable, Save/Cancel, reload, isolated
server restart, Home Screen, portrait/landscape, six app selections and existing
apps/Claude/media/Phone/status. Browser emulation does not establish physical acceptance.

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
