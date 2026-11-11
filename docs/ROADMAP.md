# ROADMAP.md — PhoneDeck milestones

Milestone status and scope. Only the current milestone is a mandate; everything below it
is direction, not approval. Steering defines each milestone as a bounded brief before it
starts (see `docs/STEERING.md` §7).

Legend: **COMPLETE** · **IN PROGRESS** · **NEXT** · **NOT STARTED** · **DEFERRED**

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

**STATUS: COMPLETE — production accepted by Steering** (status recorded 2026-11-10).
Accepted production baseline: `dc9133701d9106cc7c6dec8caae3bd2bfc53c54a` (M3.4 / PR #10).
Earlier slice receipts below retain their historical evidence boundaries. Claude-dependent
note capture is not a verified V1 capability; its unused fixed entry is replaced in the
separate post-M3 Configure slice.

**M3.1 — Media-first iPhone UI:** implementation accepted by Steering after physical iPhone 11
validation PASS (2026-11-08); GitHub consolidation merged at `14872a3a`. Implemented in
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

Current integration status: approved M3.1 merge `14872a3a` is on `origin/main`; Steering
reports M3.1 production **ACCEPTED**. M3.2.1 leaves that production server unchanged.
At the M3.1 handoff M3 overall remained **IN PROGRESS**. Final M3 production acceptance
is recorded in the current milestone status above.

**M3.2.1 — Configurable Widgets V2: physical iPhone 11 acceptance PASS; GitHub consolidation pending Steering acceptance.**
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
The **single independent focused review PASS** covers final implementation
`7c50e3e1f47e69350b898a7186d562d5f3e4e90f` against `14872a3a`. A fresh read-only Codex reviewer
inspected codec/store/wire integrity and rollback, the owner correction, regression and validation
receipts. The one major finding above is closed; no unresolved blockers, major or minor findings
remain. The reviewer did not author fixes, run builds or create files. Implementation acceptance
remains Steering's decision.

Isolated HTTPS validation used a synthetic six-app configuration, a separate token and CA,
and a process sandbox denying production configuration access. Automated server-restart checks
preserved hidden preferences, six selections, revision, document bytes and immutable V1 snapshot.
Local preview configuration, credentials, certificates, snapshots and validation artifacts remain
outside the repository and are excluded from the PR.

**Physical iPhone 11 acceptance PASS**, confirmed by Steering on 2026-11-09. The user verified
all six existing applications preserved; Save and Cancel; all four widget visibility combinations;
persistence after reload; restoration of both widgets; Spotify, Claude and Phone regression;
portrait, landscape and Home Screen. These are user-reported physical results, distinct from the
automated checks above. No additional physical checks or production V2 migration are inferred.

GitHub consolidation records that physical acceptance and aligns status notes only. The reviewed
implementation and approved ADR-017 are unchanged. Focused documentation/diff checks are run;
the existing 405-test, release-build and independent-review results are retained without rerunning
the broad suite or requesting another review. The PR targets `main` for Steering acceptance;
merge, deployment, production migration and stopping the active M3.1 server are not authorized.

Turn the deck into the intended iPhone 11 control surface.

- iPhone 11 optimized control interface (layout, touch targets, always-on behaviour).
- **Data-driven controls** — keys and widgets described by configuration, not
  `APP_SLOTS` plus layout arithmetic.
- Media — now playing and transport as the primary interaction, not a footer.
- Mac status — network, batteries, and the Mac's own state.
- **Shortcuts** — run approved macOS Shortcuts from keys, through the action registry.

## M4 — Developer Deck

**STATUS: DEFERRED — M4.1 Git Status moved to M5 by Steering** (2026-11-10).
Implementation `8a65c7bc88fecbe831cd2f1890d1486ed578e049` passed independent focused review
and physical iPhone 11 acceptance in isolation. It is preserved on `m4.1/read-only-developer`
with its existing evidence; **do not merge or deploy it**. Safe production execution needs
an independently confined worker lifecycle beyond the current simple launch model. Direct
Git loses worker restrictions; nested sandboxes fail; the inheritance exception is rejected.
No further sandbox investigation or worker implementation is authorized by the Configure task.

Add developer surface, deliberately and narrowly.

- **Repo allowlist** — the Mac decides which repositories may be observed or acted on.
- **Git status** — branch, divergence, dirty state, recent commits, for allowlisted repos.
- **Run tests** — an approved action, not a command string from the browser.
- **Approved developer actions** — a fixed, auditable set.
- **Qwen / Codex status** — agent state where it is technically justified; introduced
  only together with the collector boundary.

## M5 — Security & reliability

**M5.3-S2 — TLS private material hardening: COMPLETE (2026-11-11).**
[PR #17](https://github.com/AdrianJTorres/OldPhoneDeck/pull/17) merged to
`main` at `8e46ce8eee719c623c6e0357652fd5ec1067008f` (ADR-021).
Private TLS outputs are created at owner-only `0600` and unsafe retained identities
fail closed. One independent T3 review PASS (specific CA-regeneration finding
fixed and rechecked); 14 focused TLS/HTTPS/WSS + 5 managed-startup tests PASS;
release build zero warnings. No token-scope redesign.
Separate production permission remediation PASS: `ca.key`, `server.key` and
`server.p12` all `0600`; identity/token preserved, private backup verified.
Controlled production cutover PASS on the merged source, HTTPS/WSS and M5.2 HTTP
policy PASS; no certificate/token rotation, rollback or V2 change.
User-confirmed iPhone 11 physical PASS: Home Screen HTTPS, seven keys
(Open ChatGPT slot 6, TradingView slot 7), both widgets, Configure/Cancel,
portrait/landscape. Live revision `bf4da13b431a2bf8` retained.
No real Mac actions were executed as part of this deployment acceptance.
M5 overall and deferred M4.1 remain open; see `M5.3-TLS-PERMISSIONS.md`.
**STATUS: IN PROGRESS — M5.1, M5.2 and M5.3-S2 COMPLETE; remaining M5 work open** (2026-11-11).

**M5.1 — Reliable Startup & Recovery: COMPLETE.** Integrated in PR #12 at
`4f75b99f760b73f846be6870161cbac3590fd417`; production runs the native Aqua
user LaunchAgent `local.phonedeck` with `--managed-startup` under the retained sandbox.
Acceptance: 31 focused tests, warning-free release, one independent review, isolated
crash/restart/recovery checks, controlled production cutover, authenticated HTTP/HTTPS/WSS,
and physical iPhone 11 PASS. After a user-initiated logout/login, a new launchd-owned
process started at 17:08 CET (login at 17:07); no duplicate process or startup errors,
and token/TLS/sandbox/Shortcut approval state remained unchanged.

**Post-login V2 edit reconciled:** the user intentionally used Configure Save at 17:14 CET
to replace Activity Monitor (id `app-7`) with Safari (id `key-1`). The resulting revision
`e877d78bd16a5d15` supersedes `59018df8ab86263f`. The `unrepresentable` status
reflects inability to project the custom ID into legacy path-list format, not V2
corruption. Never overwrite this valid newer edit with `config.json.prev`.
A complete Mac reboot was not tested; login-driven startup was. Changed LAN address
still requires separately authorized TLS recovery.

Remaining M5 security work, including deferred M4.1 worker confinement and independent
security review, is separately scoped; M5 overall is not complete.

Independent review and hardening before V1.

- **Codex T3 independent review** of authentication, ingress, action authorization and
  process execution.
- **Auth** — complete assessment; resolve or explicitly accept the single-unscoped-token
  risk.
- **Ingress** — verify and complete the M2 limits; remaining timeouts, caps and edge cases.
- **HIGH risks** — resolve or explicitly accept what remains after M2.
- **Command boundaries** — prove no path from browser input to arbitrary execution; assess
  deferred M4.1 Git Status worker confinement and lifecycle as a separately scoped M5 task.
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

## M3.3 — macOS Shortcuts

**STATUS: FUNCTIONAL AND PHYSICAL IPHONE ACCEPTANCE PASS; GITHUB CONSOLIDATION FOR INTEGRATION; PRODUCTION DEPLOYMENT PENDING (2026-11-09).**
Approved base `96c637f84bfaf5872173b440178459906c7eda43`, branch `m3.3/shortcuts`,
Codex WRITE_OWNER. ADR-018 records the server-owned UUID allowlist and execution policy.
The existing seven-key ES5 editor supports mixed apps and explicitly approved Shortcuts,
complete-control V2 saves, stable IDs/order/metadata, visible unavailable/inert entries,
Save/Cancel and shared widget/revision/atomic recovery semantics. Legacy app-only writes
refuse mixed documents. Default approvals are empty; only the harmless Steering-approved
UUID test may be configured in the isolated preview's private file outside Git.

Authenticated asynchronous runs have one slot, no execution queue or retries, fresh UUID
availability checks, closed stdin, bounded output, a 30-second execution deadline and
process cleanup. Feedback distinguishes Running, CLI completion, failure, timeout with
unknown effects, busy, unauthorized and unavailable. ADR-018 records the design and initial
Terminal proof; the physical server-context evidence below supersedes the implementation-time
acceptance-pending notes. No further real Shortcut execution, production changes, token/TLS
rotation, merge or deployment is authorized by this GitHub consolidation.

Implementation validation: **422 tests in 48 suites PASS**, using fake Shortcut executors.
The complete shipped inline script parses as ES5 with Node-bundled Acorn 8.18.0.
Tests cover approved/denied UUIDs, current/missing catalogue membership, one winner under
concurrent starts, busy/failure/timeout/no retry, bounded fake-process cleanup, private approval
file refusal, full mixed metadata/order/widget preservation, stale/concurrent saves, verified
failed-write recovery, seven retained application controls and client behavior. HTTP tests use
production admission/handlers with fake executors; no real Shortcut was executed.

The single fresh independent T3 review of `8f69d023153eb6f2c4dbb7d39a415f8c892d5495`
reported no blockers or major findings and one minor feedback-lifetime gap: a blackholed
execution/status HTTP request could leave the phone showing Busy indefinitely. The owner
added a Shortcut-only five-second watchdog that aborts hung requests, reports unknown
outcome, clears local polling and ignores late callbacks without resubmitting execution.
**33 affected client/launcher tests in three suites PASS**, including a new fake-timer
regression for both POST and GET blackholes and late success replies. Full-script ES5
parsing still passes. Focused re-review of correction `76abb72abaaac15bc132cafa08eae64c58119632` is **PASS**;
the one minor finding is closed with no remaining review findings. The broad 422-test
baseline is retained. Existing execution/completion evidence and Steering's physical
acceptance decision are recorded below; no broad review is repeated for consolidation.


Final release build: **PASS with zero warnings**. Isolated HTTPS preview uses separate
credentials, a separate CA, seven synthetic application controls and only the supplied
harmless test UUID in its private 0600 server-owned allowlist. No production material is
read/copied or rotated. The preview process sandbox denies production configuration access.
Verified HTTPS, shipped-resource identity, authentication and denied-UUID refusal pass.
Real-browser checks pass long-press, seven-key removal-before-add, mixed Save/reload and
ordering, byte-exact Cancel, all four widget combinations and five viewport cases including
480×320. Effective media targets remain at least 44 CSS px. During automated browser checks,
all Shortcut feedback requests and other Mac-action POSTs were intercepted before network; no real Shortcut was executed
by those checks. At the implementation handoff the preview had its original seven complete
app controls restored, both widgets visible, and the approved test Shortcut unselected.
Final UI labels mention apps and Shortcuts.

**Steering acceptance (2026-11-09): M3.3 functional and physical iPhone acceptance PASS**
for implementation `873848566503e169ec98cfbd228c5e4ba98ac851`. The user ran the harmless test
from the isolated iPhone 11 HTTPS preview on port 8077 and observed Completed with no consent
dialog or visible Mac action; a Text-only Shortcut need not produce a visible Mac action.
Existing macOS logs verify execution and workflow completion. The preview implementation
requires normal CLI exit 0 for Completed; numeric exit status was not independently persisted.
Three CLI executions were observed at 14:36:16, 14:36:36 and 14:36:56 CET. The user reports
very likely pressing the key three times, plausibly separate user interactions. Exact HTTP
request-to-process correlation is unavailable; no automatic-duplication defect is proven.
Steering lifted the previous blocker and subsequently accepted functional and physical behavior.

Final focused verification retained the existing test/review evidence and added only the missing
browser touch-dispatch regression with fake responses: one touch sends one execution POST,
a touch while Busy adds none, polling/timeout adds no retry, and a separate mouse click sends
one POST. All action requests were intercepted before the server and configuration was unchanged.
The code and existing fake-executor tests also verify server-side concurrent-run rejection,
timeout-unknown never becoming success, and the CLI exit-0 completion gate.

**Current integration status (2026-11-09): M3.3 COMPLETE.** Steering confirms the slice is
merged to `main` at `c3fdff8906f88decfd8fdde4335d8bad17df953f`, deployed and physically
accepted on iPhone 11. The implementation and review evidence above is retained; this
status update records Steering's production acceptance rather than a new device test.

## M3.4 — Minimal Data-Driven UI Closure

**STATUS: COMPLETE — implementation and physical iPhone 11 acceptance PASS**, confirmed by
Steering on 2026-11-09. GitHub integration: [PR #10](https://github.com/AdrianJTorres/OldPhoneDeck/pull/10).
Base: `c3fdff8906f88decfd8fdde4335d8bad17df953f`.

Remaining ADR-010 gap: controls already render from complete configuration in saved order;
widget descriptors drove visibility, but each responsive branch explicitly positioned Internet
and Batteries. M3.4 reuses `WIDGET_CARDS` for one row/column placement helper. Each branch
supplies a status region; adding a card template/descriptor no longer needs per-card layout
math in three branches. A descriptor retains Internet's legacy height; battery content sizing,
seven editable keys, control IDs/order, editor, hidden slots and media/Phone geometry remain.
Fixed screen regions, templates, collectors and the two persisted visibility fields are deliberate
integration points, not an arbitrary dashboard API. No framework or persistence/auth change.

Validation: 14 focused Swift Testing tests pass (launcher client, mixed-control client and two
new widget-layout tests). The extension test inserts a third descriptor into the existing row
and column without changing `layout()`. The complete shipped script parses as ES5 with Acorn
in ES5 mode. Headless Chrome compares exact geometry/key labels against the pinned base across
five viewport/safe-area cases and all four widget combinations (20 comparisons); media targets
remain at least 44 CSS px. Editor reorder/Save/reload preserves IDs and complete metadata;
Cancel is byte-exact. The final release build succeeds with zero warnings. An initial sandboxed
build failed on inaccessible compiler caches; the unrestricted local build and final checks pass.

Focused independent read-only review: **PASS**, no blockers, majors or minors. No broad test
rerun, real app/Shortcut execution, production modification, merge or deployment occurred.
Isolated HTTPS preview uses ports 8085/8087/8088, fresh private configuration/token/TLS and no
approved Shortcuts, with production configuration denied by its sandbox. Its original seven
synthetic controls and both widgets are restored. Browser checks do not establish physical
acceptance by themselves. Steering subsequently confirmed implementation and physical iPhone 11
acceptance **PASS** for `46133b6b0b36daf9ce9898297d11523034e06c60` and authorized publication,
PR creation, merge and GitHub verification. The accepted product/test blobs remain unchanged;
the follow-up records status only. PR #10 integrates that implementation into `main` using the
established merge-commit method; this integration record takes effect with that merge.
Existing tests/build/browser/independent-review evidence is reused without repetition.
**Subsequent Steering closure:** M3.4 is deployed and production accepted at
`dc9133701d9106cc7c6dec8caae3bd2bfc53c54a`; M3 is COMPLETE. This supersedes the earlier
integration-only authorization boundary above. This historical M3.3 task did not alter
production; M4.1 is preserved and deferred to M5.


## Post-M3 UX — Configure entry

**STATUS: Configure implementation and physical iPhone 11 acceptance PASS**, confirmed by
Steering on 2026-11-10 for `af924143aae1bed52680cee9dc65e0ae4c4ce3f6`.
Base: current `main`, `dc9133701d9106cc7c6dec8caae3bd2bfc53c54a`.
Replace only the fixed Claude key's visible icon/label and tap/hold interaction with Configure,
opening the existing `openEditor` flow. Seven configurable controls, V2 persistence, widgets,
responsive geometry and legacy Claude backend remain unchanged. No M4.1 code is included;
no new architecture, execution/security changes or production changes. GitHub publication
and merge are separately authorized below; production deployment remains excluded.
Validation: 15 focused launcher/mixed-control/widget tests PASS, including Configure tap/hold
opening the editor without dispatching actions, byte-preserving Cancel, complete seven-control
IDs/order and Save handling. Full script parses as ES5. Isolated HTTPS browser tests verify
Save/reorder/reload, all widget combinations, five editor viewport cases and 20 exact baseline
geometry comparisons. Release build PASS with zero warnings. The preview uses separate V2
fixtures/token/TLS on 8105/8107/8108 and reuses the existing isolation profile unchanged;
seven original synthetic controls and both widgets are restored for handoff. No Mac actions
were dispatched. Browser checks do not establish physical iPhone acceptance.
Steering confirms physical Configure iPhone 11 **PASS** and authorizes publication, PR creation,
merge with the established merge-commit method and GitHub verification. The accepted product
and test blobs remain unchanged; this follow-up records acceptance only. Existing evidence is
reused without broad tests or another review. Deferred M4.1 commit/branch/evidence remain
preserved and excluded. **Historical integration gate:** deployment was not authorized by that integration task.
Steering now confirms Configure deployed and physically accepted, COMPLETE (2026-11-10),
on main `c15ccb69cd5930afc941a46f79671cfedd144593`. M5.1 does not change production.
M5.1 stops for Steering.


### M5.2 — Cleartext HTTP security boundary

**COMPLETE — merged, production deployed and physical iPhone 11 accepted by Steering (2026-11-10).**
Based on authorized main `28a48a00bf3bda047e6eba29e704574dc9798020`, dedicated local
branch `m5.2/cleartext-http-boundary`. ADR-020 records the policy.

A synthetic native HTTP fixture connected through the Mac's LAN address confirmed the old
bearer-authenticated `/launch` route reached a fake executor over plaintext. The candidate
now denies every remote cleartext API before token comparison/body retention. HTTP retains
public credential-free onboarding/profile GETs, plus authenticated camera GETs only from
actual numeric IPv4/IPv6 loopback peers. All controls require HTTPS even locally. The HTTP
page no longer runs the token-using deck; no redirect carries a token. Peer/TLS identity comes
from Network.framework, never Host or forwarded headers. HTTPS route behavior and WSS stay
intact; localhost OBS/MJPEG keeps its existing URL and authentication.

**85 focused tests in nine suites PASS**, including real isolated LAN-address IPv4/IPv6
HTTP denials, forwarded-header spoof attempts, pre-body refusal/no fake action execution,
loopback/mapped-address camera access, all-route HTTPS acceptance, invalid HTTP/HTTPS/WSS
tokens, WSS ping past the auth deadline and WSS frame delivery to localhost MJPEG. The
focused run also covers existing parser/connection, fake app-action, launcher-store and
Shortcut HTTP behavior. **Release build PASS, zero warnings.** Only synthetic credentials,
ephemeral TLS imported in memory and fake executors were used; no real apps/Shortcuts ran.
Evidence: `../operations/m5.2-http-boundary/` (`original-exposure.log`, `focused-tests.log`,
`release-build.log`). Physical iPhone/OBS application validation and deployment are not claimed.

Production service, latest intentional Safari control/V2 state, widgets, approvals, secrets,
sandbox and LaunchAgent remain untouched. No production secrets were accessed or copied.
M4.1 remains deferred; token scopes and broader M5 risks remain open. No push, merge or deploy.

One fresh independent read-only T3 review: **PASS, no blocker, major or minor findings**.
The reviewer inspected the changed transport/admission boundary, native TLS/WSS wiring,
regression coverage and retained logs without writing files or running builds/tests.
Ready for Steering to authorize GitHub integration; no push, merge or production action taken.


M5.2 operational health reconciliation: Steering accepted the original security implementation
`0263f78` and authorized a narrow compatibility follow-up plus GitHub publication. The active
M5.1 runbook now makes pinned authenticated HTTPS and WSS authoritative and separates M5.2
HTTP denial from service health. Explicit release policy retains pre-boundary M5.1 rollback
expectations and valid custom V2 IDs such as Safari `key-1`. The original deployment-local
helper remains unchanged; a corrected adapter is staged separately using the tracked read-only
health checker. Only focused helper/documentation checks run; accepted 85-test/build/T3
evidence is reused. Production and deferred M4.1 remain untouched; merge is not authorized.

Focused follow-up validation: **12 Python helper tests PASS**; **one native Swift test with
both M5.2 and M5.1 release-policy cases PASS**, exercising the separately staged adapter.
HTTPS/WSS checks pin generated fixture certificates and retain CA verification. No production
helper was installed and no production credential/configuration was opened or changed.

**Steering production closure (2026-11-10): M5.2 COMPLETE.** PR #14 was merged into
`main` at `577420fbdad00c3892cafc845502c40b74f9a229`. Codex reported a
controlled M5.2 cutover via the existing Aqua LaunchAgent `gui/501/local.phonedeck`
(PID 85330 at 21:10 CET), release build PASS without warnings, authenticated HTTPS/WSS,
IPv4/IPv6 LAN HTTP control denials, authenticated loopback OBS/MJPEG protocol PASS,
and release-aware health PASS. Exact latest production V2 bytes/revision
`e877d78bd16a5d15`, all seven controls including Safari `key-1`, widget settings,
absent Shortcut approvals, TLS/token identities and sandbox were preserved. Verified
rollback assets remain available; rollback was not required.

The user then confirmed physical iPhone 11 Home Screen acceptance over HTTPS 8047:
seven controls and Safari `key-1`, Configure/Cancel, widgets, multimedia and both
orientations all PASS without executing real apps or Shortcuts. Actual OBS rendering,
app/Shortcut execution and another logout/reboot were not tested in M5.2.
M5.1 login-startup evidence remains accepted, and M4.1 stays deferred.
**M5 overall remains in progress:** unscoped bearer token and other independent
security/reliability risks still require later scope and decisions.
This is a documentation-only closure; no production operation or code change.
