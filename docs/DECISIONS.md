# DECISIONS.md — Architecture Decision Records

Lightweight ADRs. One decision per record: context, decision, consequence. Accepted ADRs
are not edited — supersede them with a new ADR and mark the old one `Superseded by`.

Known risks discovered in M1 are **not** decisions; they are recorded in
`docs/ARCHITECTURE.md` §9, which names the milestone that owns each one — M2 for the
minimum ingress items, M5 for the independent review and the remaining hardening.

---

## ADR-001 — Use OldPhoneDeck as the PhoneDeck foundation

**Status:** Accepted · 2026-11-03

**Context.** PhoneDeck needs a phone-as-control-surface for a Mac. Upstream
`GLAUCOMA82/OldPhoneDeck` already implements the hard parts: a dependency-free Swift
server, an ES5 client that runs on iOS 8/9, private-CA HTTPS for modern Safari, camera and
mic ingest, app launching, AppleScript media control, and telemetry widgets. It is MIT
licensed, builds in ~105 s with `swift build -c release`, and was physically verified on
the iPhone 11.

**Decision.** PhoneDeck is an incremental evolution of a fork of OldPhoneDeck. Upstream
remains a read-only reference (`upstream` remote). PhoneDeck is not a rewrite, and the
existing modules are reused rather than replaced.

**Consequences.** Work is additive and must keep upstream behaviour working. Improvements
that are generally useful may be contributed upstream later, but the fork is the product.
`main` tracks the baseline `e622184` until milestones land.

---

## ADR-002 — iPhone 11 is the primary interactive control surface

**Status:** Accepted · 2026-11-03

**Context.** Two devices are available: an iPhone 11 and an iPhone 7 Plus. The project
needs exactly one design and acceptance target, and the iPhone 11 has been the physical
acceptance device since M0.

**Decision.** The iPhone 11 is the primary target. Every milestone that changes the UI is
accepted on the physical iPhone 11, in both landscape and portrait, including Home Screen
standalone mode.

**Consequences.** Interaction design is optimised for a modern phone held in one or two
hands. Compatibility with old iOS remains a code constraint (ADR-004) even though the
4S-class device is no longer the acceptance target.

---

## ADR-003 — iPhone 7 Plus is reserved for a future information/dashboard role

**Status:** Accepted · 2026-11-03

**Context.** The 7 Plus has a large screen and is well suited to an always-on display.
Supporting a second device now would add scope and a second acceptance surface before the
primary one is finished.

**Decision.** The iPhone 7 Plus is **intentionally reserved** for a later, read-only
dashboard role. This is a product prioritisation, **not** a statement that the device is
incapable of running secure browser features. No milestone before V1 depends on it, and V1
must not be delayed by it.

**Consequences.** Nothing in M2–M6 may assume a second simultaneous client. If the
dashboard role is taken up later, it starts from the existing collector/telemetry seams
rather than new architecture, and must not complicate the iPhone 11 path.

---

## ADR-004 — Preserve the Swift + browser architecture

**Status:** Accepted · 2026-11-03

**Context.** The project's value comes partly from its operability: one binary, one HTML
file, no build step for the client, no runtime to install, no dependency tree to audit.
Alternatives (Electron, React, Node, a database, a web framework) would each add a supply
chain and a deployment story to solve problems this project does not have.

**Decision.** Stay on Swift + SwiftPM with zero/minimal third-party dependencies, and keep
the client as a single hand-written ES5 file that runs in Safari on an old iPhone. No
Electron, React, Node, database, or web framework. Adding a dependency requires an ADR and
a Steering decision.

**Consequences.** Some ergonomics are given up deliberately: no component model, no
package manager for the UI, hand-written layout and state. The ES5 constraint remains a
hard limit on frontend work, including M3.

---

## ADR-005 — No arbitrary shell execution exposed to the phone

**Status:** Accepted · 2026-11-03

**Context.** The phone holds a token that already authorises app launching and text
injection into Claude. Any endpoint that accepted a command or a path and executed it
would turn a leaked token — or a single ingress bug — into arbitrary code execution on the
Mac.

**Decision.** No product endpoint may accept a command, binary path, or script and execute
it. The Mac decides what can run; the phone only identifies which approved action to
invoke. `Process` invocations keep fixed absolute binaries and fixed argv, as they do
today.

**Consequences.** Every new capability must be expressed as a pre-approved action. This is
the constraint that makes ADR-006 necessary, and it is a review checklist item for Codex
in M5.

---

## ADR-006 — Use an allowlisted Action boundary

**Status:** Accepted · 2026-11-03 · Target: M2

**Context.** Today each capability is a `case` in the route switch in `main.swift`, with
its own validation, dispatch and response. App launching, Shortcuts, developer actions,
Git actions and AI controls are all the same shape: "invoke a thing the Mac has approved".
`Apps.isKnown` already demonstrates the right validation pattern.

**Decision.** Introduce one internal representation of an approved action — identifier,
display metadata, validated parameters, and a server-side execution allowlist. Existing
capabilities become the first implementations. New capabilities must use it rather than
adding another ad-hoc endpoint.

**Consequences.** M2 owns the design. Until it lands, no new action-shaped endpoint should
be added, because it would become migration debt. The boundary is internal to the single
executable target; it does not require new modules or dependencies.

---

## ADR-007 — Move configuration toward a versioned schema

**Status:** Accepted · 2026-11-03 · Target: M2

**Context.** Configuration is `~/.oldphonedeck/launcher.json`: a bare array of app paths.
`Launcher.selected()` returns `nil` both when the file is absent and when it cannot be
parsed, so any schema change silently resets the user's layout. The format cannot express
controls, action types, metadata or layout.

**Decision.** Introduce a versioned configuration document that can represent controls,
action types, metadata and future layout configuration. Migration is explicit, runs on
read, and preserves the existing launcher selection. Unknown or newer versions are handled
deliberately rather than degrading to "never configured".

**Consequences.** M2 owns the schema and migration. The old file is read, migrated and
retained until the new format is proven on the physical device. Writing configuration
remains a server-side operation; the phone never supplies a file path.

---

## ADR-008 — Ingress hardening precedes high-consequence developer actions

**Status:** Accepted · 2026-11-03 · Target: M2 minimum, M5 complete

**Context.** M1 found that request bodies are buffered (up to 512 MB) before the token is
checked, there are no header/connection/idle limits, MJPEG viewers are uncapped, and a
single unscoped token authorises everything. Today the blast radius is "launch apps and
control music". M4 would add Git operations and test runs.

**Decision.** Before any high-consequence action exists, enforce limits **before** body
buffering, bound connections and keep one authorization boundary between deck control and
developer actions. Full authentication review belongs to M5 (Codex, T3), but the minimum
must precede M3/M4 features.

**Consequences.** M2 includes the minimum ingress hardening even though it is not a
feature: limits enforced before large buffering, basic connection/resource bounds, and the
minimum authorization boundary before higher-consequence actions. M5 performs the
independent T3 review, completes the assessment and finishes the remaining hardening — it
verifies and extends the M2 boundary rather than introducing it from scratch.

---

## ADR-009 — Collector abstraction is introduced when additional telemetry requires it

**Status:** Accepted · 2026-11-03 · Target: M4 (just-in-time)

**Context.** `Stats` and `Music` already follow the same pattern: a long-lived timer on a
private queue, a lock-protected snapshot, and a hand-written merge into `/stats`. Git
status and agent status would be two more of the same shape.

**Decision.** Do not build a collector registry now. Introduce it at the point where the
next telemetry source would otherwise require editing the route table and the `/stats`
payload by hand — that is, when M4 adds Git or agent status.

**Consequences.** No speculative abstraction in M2. When the boundary arrives, existing
collectors are refactored onto it; until then `Stats`/`Music` remain the reference pattern
that new collectors copy.

---

## ADR-010 — Frontend becomes data-driven during PhoneDeck UI work, without a web framework

**Status:** Accepted · 2026-11-03 · Target: M3

**Context.** The UI hardcodes 7 app slots plus a fixed "Take note" key, and every widget's
geometry lives in `layout()` as pixel arithmetic for two orientations. Adding a control or
a card means editing layout math. Yet the single-file ES5 delivery is the reason the client
works on an old iPhone with no build step.

**Decision.** During M3, make controls and widgets data-driven — described by
configuration and rendered by a small registry — while keeping one ES5 file, no build step,
and no framework.

**Consequences.** Layout stops being arithmetic and becomes data plus a small set of
stacks. iOS 8/9 syntax constraints and the existing touch-handling approach remain.
Feature work that adds a hardcoded card before M3 is discouraged.

---

## ADR-011 — Hybrid Coding routing: T1/T2 to Qwen Code, T3 to Codex, Steering retains authority

**Status:** Accepted · 2026-11-03

**Context.** Work varies from one-line documentation edits to security-sensitive ingress
changes. Using one agent for everything either over-spends on routine work or under-spends
on risk. Independent review is also incompatible with self-review.

**Decision.** Route by tier: T1/T2 (scoped implementation, analysis, routine terminal work,
documentation) to Qwen Code; T3 (security-sensitive, hard debugging, architecture-sensitive
changes) to Codex, which also performs independent review of work it did not author.
Steering (the human owner) decides scope, milestones and architectural acceptance.

**Consequences.** A reviewer is never the author. Architecture changes require an ADR and
an explicit Steering decision rather than an agent's judgement call.

---

## ADR-012 — One WRITE_OWNER per branch/worktree

**Status:** Accepted · 2026-11-03

**Context.** Two agents writing one working tree produce interleaved, unattributable
changes and destroyed context. The M1 brief named a single WRITE_OWNER explicitly.

**Decision.** Exactly one agent may write to a given branch or worktree, named in the
brief. All other agents on that branch are read-only: they may read, build and run
non-destructive commands, but may not edit, stage or commit. Parallel writing requires a
separate worktree.

**Consequences.** Analysis and review are cleanly separated from authorship. A read-only
agent that believes an edit is required stops and reports instead of writing.

---

## ADR-013 — Routine terminal work is performed by coding agents, not the human user

**Status:** Accepted · 2026-11-03

**Context.** The human owner is the bottleneck and the authority. Asking them to run
builds, greps, `git` commands or `curl` checks wastes their attention and loses the
evidence an agent needs to reason.

**Decision.** Agents execute all routine terminal operations themselves and report the
actual output. Human intervention is reserved for what an agent cannot do: macOS
permission dialogs (Accessibility, Automation, Local Network), credentials and
authentication, physical-device checks on the iPhone, and scope or architecture decisions.

**Consequences.** Agents must show real command output rather than instructing the user,
and must state clearly when a step genuinely needs the human.

---

## Implementation note — ADR-008 / M2.1

M2.1 implements only the HTTP admission portion of ADR-008. Bounded incremental parsing
produces headers for an application-supplied admission closure; the transport does not
know the token. `DeckRoute` is the single method/path/body-limit catalog used by admission
and the handler switch, shared by HTTP and HTTPS. Bodies are retained only after admission.

Header and admitted-body absolute deadlines are each 10 seconds; expiry cancels the
connection. Their exact limits and error behavior are recorded in `ARCHITECTURE.md` §5.
One Swift Testing target tests parsing/admission and real local HTTP connections without app
startup or user configuration. The user explicitly authorized bundled Swift Testing
instead of XCTest because this CLT installation lacks XCTest. Its framework search and
optional-overlay flags are documented in `AGENTS.md`; no toolchain files were changed.
No library target, dependency or auth scheme was added.

This implements the accepted direction without changing ADR-008. M2.1 has since completed
independent Codex review (PASS, no findings) and Steering acceptance; the implementation
commit is `4dd7fae593934053b5595b01cb52735351d42e18`. Connection and media/resource caps
belong to M2.2; the Action boundary was subsequently delivered in M2.3, and the M5
independent assessment is still outstanding.

---

## ADR-014 — Explicit bounded HTTP and media ownership (M2.2)

**Status:** Accepted by Steering · 2026-11-03. Independent review found no blockers/majors;
one minor framework-size test-coverage finding was corrected and mutation-verified (63/63
tests pass). Physical iPhone streaming, fresh frames, camera switching, reconnection and
deck polling passed. Continuous live MJPEG and mic-to-Mac playback were not physically
verified; BlackHole was unavailable.

**Context.** M2.1 bounds each HTTP request but does not cap simultaneous connections or
media producers/viewers. The per-viewer frame-drop guard cannot prevent JPEGs from
accumulating between the media and HTTP queues. Audio previously checked the queued total
before adding the next chunk, allowing the intended playback bound to be exceeded.

**Decision.** Use one explicit 32-slot HTTP lease budget shared by HTTP/HTTPS and returned
idempotently from connection close. Overflow closes immediately before transport startup;
attempting an overload response would require retaining another active connection. Keep
two MJPEG viewers within that budget, with synchronous close removal and a receive watching
idle streams for peer closure. Viewer overflow can safely return 503 inside an HTTP slot.

The media queue owns two WebSocket slots and one producer slot, with five seconds from
readiness for the existing first binary `H` + token. A second producer cannot replace the
first. The framework ceiling is 2 MiB; application checks bound authentication, JPEG
envelopes and PCM messages. Keep one latest pending frame between queues and the existing
one-frame-in-flight viewer drop policy. Reserve proposed audio totals against 4000 frames
before conversion; release on allocation failure or playback completion.

**Consequences.** Slow clients occupy bounded slots; fairness, generalized rate limiting,
pre-ready WS handshake deadlines, authenticated idle deadlines and stalled sends remain
M5 work. No new authentication protocol, Action Registry, configuration schema, TLS
lifecycle or UI is introduced. JPEG envelope checks do not decode/validate the full image.
Whole audio chunks that exceed the remaining playback budget are dropped. Tests use
loopback connections and a temporary memory-only TLS identity, not user configuration,
certificates installed in a keychain, physical devices or BlackHole.

---

## Implementation note — ADR-005 / ADR-006 / M2.3

**Status:** Accepted by Steering · 2026-11-06. Implemented on
`m2.3/app-action-boundary`; review-findings closure commit
`6d8cd813690e6d159562c8307c096fd8738023e9`.
Initial independent Codex review: PASS WITH MINOR FINDINGS (three minor, no major/blocker).
All three were corrected, and focused Codex re-review returned PASS with zero findings.
The full Swift Testing suite passed 90/90 (12 suites), and the release build passed
without warnings. Physical iPhone 11 testing and a live real-app 200 acceptance-path
check were not claimed for this slice. M2 as a whole remains IN PROGRESS.

M2.3 implements the first slice of ADR-006 without changing ADR-005 or ADR-006, and
without touching ADR-007 (versioned configuration is a later slice).

**What now exists.** One internal typed action boundary in `Sources/oldphonedeck/ActionRegistry.swift`,
inside the existing single executable target: no new module, no dependency, no framework.
`ActionID` validates identifier syntax (lowercase dotted name, at most 64 bytes) and the
identifier must also name an entry in a server-authored descriptor table, so an unknown or
malformed identifier fails closed and there is no registration entry point a client could
reach. `ActionDescriptor` carries a display name and a kind; metadata describes an action,
never authorizes one, and is not persisted. `ActionParameters` can only carry an application
path. `ActionRegistry.dispatch` re-validates parameters (non-empty, at most 4096 UTF-8
bytes) and then requires exact membership in the catalog the server itself produced, before
`AppLaunchExecutor` runs. Every rejection returns before the executor is reached.

**ADR-005 is preserved strictly.** An application path is data: no parameter shape can
express a command, argv element, shell source, environment variable, working directory,
script or process descriptor. No `Process`, no shell-out and no generic command runner is
added. The only execution remains the existing `NSWorkspace` app launch, reached only after
server-side authorization, with the pre-existing `DispatchQueue.main.async` hand-off to
`Apps.launch` intact. A `.app` suffix, a plausible directory or a matching display name
authorizes nothing.

**Authorization moved inside the boundary**, out of the HTTP route, so a future caller that
reaches the registry directly is still authorized. `POST /launch` became a thin adapter:
the server names `app.launch`, the client supplies only data, and no client-supplied
identifier is decoded. Wire compatibility is unchanged — same method, path, parameters,
`200 ok` for an accepted launch, `404 unknown app` for every rejection, and the existing
`403`/`405`/`411`/`413` admission behaviour. `ok` still acknowledges acceptance and
dispatch, not activation. No new endpoint, no new route, no action permissions or token
scopes, no persistence, no configuration schema, no plugin loader and no UI change.
`/media`, `/claude`, `/speedtest`, `/launcher` and `/icon` remain legacy and are not
migrated; Shortcuts, Git and developer actions are not created.

**Testability.** The catalog resolver and the execution callback are injected, so tests use
a deterministic fake catalog and a recording executor and never call NSWorkspace, need GUI
automation or Accessibility permission, or require a physical device.

**Known limitations.** Exactly one action is registered, so the boundary is proven with a
single capability rather than a general framework; adding an action is a deliberate code
change, not configuration. Path comparison stays exact string membership with no
normalization, matching pre-M2.3 behaviour, so symlinked or traversal-spelled variants of
an approved path are rejected rather than resolved (see the next section). Each dispatch
re-runs the existing application-directory scan (`Apps.list()`), an unchanged cost.
Rejection reasons are distinguished internally but collapse to one `404` on the wire for
compatibility. Metadata is not exposed to the client and not persisted.

**Filesystem trust limits (inherited; residual risk recorded for M5).** Authorization
compares exact path **strings** against the catalog that `Apps.list()` builds with
`contentsOfDirectory` over five directories and a `.app` suffix filter (`Control.swift`).
It does not resolve, canonicalize or pin a filesystem object: no `realpath`, no
inode/device identity, no `O_NOFOLLOW`, no bundle-identifier or code-signing check, and no
re-check at execution time. Catalog entries may themselves be **symlinks** — on this Mac
`/Applications/Safari.app` links to `../System/Cryptexes/App/System/Applications/Safari.app`
— and `Apps.launch` passes the string to `NSWorkspace.openApplication`, which resolves it
when it runs. Because execution is scheduled asynchronously on the main queue, a target
could in principle be substituted between authorization and launch (a TOCTOU window), so an
authorized path could end up naming a different bundle than the one that was enumerated.

This is **inherited unchanged** from the pre-M2.3 route, which performed the same
`Apps.isKnown` string check and the same asynchronous `NSWorkspace` launch. M2.3 moves the
check inside the action boundary; it neither widens nor narrows what the filesystem is
trusted to do. Exploiting the window requires the ability to modify the local filesystem in
a scanned directory (`/Applications`, `/Applications/Utilities`, `/System/Applications`,
`/System/Applications/Utilities` or the user's `~/Applications`) — an attacker with that
write access already has local code-execution capability on macOS, and the system
directories are root-owned and SIP-protected. **No new HTTP-only exploit was identified:**
nothing a remote client can send influences which paths the catalog contains, and unapproved
or near-miss strings are still rejected before execution.

M2.3 therefore does **not** redesign the filesystem policy: no path normalization, no
symlink resolution, no object pinning, and no change to `Apps.list()`, `Apps.isKnown`,
`Apps.launch` or launcher persistence. Resolution or explicit acceptance of this residual
risk belongs to **M5** (independent T3 review of action authorization and process
execution), where it should be assessed together with the unscoped-token finding.

**Evidence.** 90 Swift Testing tests pass (63 retained M2.1/M2.2 plus 27 new, of which four
are parameterized into 44 cases); `swift build -c release` succeeds with no new warnings;
the release binary was exercised on isolated ports with rejection paths only, so no
application was launched and the real configuration was not written. Mutations — removing
the catalog gate, removing parameter validation, removing the main-queue dispatch, and
letting unknown identifiers fall back to the registered action — each turned the relevant
tests red and were reverted; with the catalog gate **and** parameter validation removed
simultaneously, the suite still fails closed with no test able to reach NSWorkspace, because
no test constructs the production `ActionRegistry()`.

---

## ADR-015 — Configuration V1 document shape

**Status:** Accepted by Steering · 2026-11-06 · Target: M2.4. The final independent Codex
review returned **PASS** on 2026-11-06 with no unresolved major or minor findings. Two earlier
review rounds found four defects — a `Double`-widened version, a size cap measured only on the
bytes as read, a lenient `JSONSerialization` reader, and a truncated exponent accumulator that
let `10^9000000` read as version 1. All four are closed; they are kept as historical evidence in
the ROADMAP M2.4 entry and in rules 6 and 7 below, not as open findings. This **elaborates**
ADR-007, which stays accepted and unedited; it does not supersede it. ADR-007 decided that
configuration becomes a versioned document with explicit migration. This record decides what that
document looks like.

**Context.** `launcher.json` is a bare JSON array of application paths, and
`Launcher.selected()` returns `nil` for an absent file, an unreadable file and an
unparseable file alike, so any format change silently resets the user's layout. M3 needs
controls with identities, action types and metadata (ADR-010), and M2.3 established that an
action is executable only if `ActionRegistry` resolves and authorizes it. A configuration
format therefore has to carry action identifiers without being able to grant them authority,
and it has to fail loudly rather than degrade to "never configured".

**Decision.** Configuration V1 is a JSON **object** — `{"version": 1, "controls": […]}` —
while the legacy format stays a JSON **array**, so the root type alone discriminates them
with no sentinel key and no probing. Each control carries a stable opaque `id` (lowercase
dashed name, ≤64 bytes, unique per document), an `action` identifier validated by the
existing `ActionID` type, flat `String → String` `parameters`, and optional `presentation`
metadata holding only a bounded `title`.

Seven rules carry the weight:

1. **Strict unknown keys.** A `version: 1` document with a key this build does not know is
   malformed. Such a document was not written by this binary, and ADR-007 exists precisely to
   stop that case from silently resetting the deck. Layout extensibility therefore comes from
   a future V2 and an in-memory V1→V2 migration, not from a reserved opaque subtree: an
   uninterpreted `[String: Any]` subtree cannot be `Equatable`, which would give up the exact
   round trips that make a pure codec worth having.
2. **The version is identified before any V1 structural or unknown-key check.** A newer
   document legitimately carries keys V1 has never heard of, and reporting "unknown key" would
   describe a newer file as a corrupt one. `version > 1` is `.unsupportedVersion`; `version < 1`
   is malformed, because no version below 1 ever existed and telling a user to upgrade a
   corrupt file is a misleading diagnosis.
3. **Configuration validity is not action authorization.** An action identifier that is
   syntactically valid but not registered decodes successfully, with its parameters preserved
   as inert `.unmodeled` data. Making it a decode error would mean that adding or removing an
   action in code could invalidate a user's whole deck. `.unmodeled` has no conversion to
   `ActionParameters`, so no document can make an unregistered action executable; `.appPath`
   is the only convertible shape, and what it yields is still only data that
   `ActionRegistry.dispatch` re-validates and re-authorizes against `Apps.isKnown`.
4. **Migration is purely syntactic and never drops an entry.** `migrateToV1` performs no
   `Apps.list()`, no `Apps.isKnown`, no normalization, no sorting, no deduplication and no
   truncation: dropping one entry would shift every later key and change what the phone
   renders. Order, duplicates, empty strings and an intentionally empty array are all
   preserved. An entry that cannot be represented fails the whole migration loudly instead of
   vanishing from it. Ids are positional (`app-1`, `app-2`, …) because a legacy array may
   legitimately hold the same path twice and a path-derived id would collide, turning a valid
   legacy document into an invalid V1 one. `legacySelection` is the **lossless** inverse, not a
   projection: it returns a selection only when migrating that selection back reproduces the
   document exactly, so it rejects unregistered actions, `.unmodeled` parameters, any
   presentation title, and any control id migration would not have synthesized — custom,
   reordered or gapped. It verifies this by re-running the migration and comparing, rather than
   by restating migration's rules, so the two directions cannot drift apart; the cost is one
   extra pass over the document per call, acceptable on a configuration read path.
5. **The encoder is as strict as the decoder because it does not restate the decoder's rules.**
   It serializes, then requires its own output to decode back to the value it was given, so the
   two directions cannot drift apart and an in-memory configuration that could not be read back
   is rejected before it is written rather than discovered on the next launch.
6. **Reading is done by the codec's own strict RFC 8259 scanner, not by `JSONSerialization`.**
   Two properties of configuration cannot be retro-fitted onto a lenient reader. The first is
   syntax: `JSONSerialization` accepts a trailing comma (`{"version":1,"controls":[],}` and
   `["/a.app",]` both parse), so a truncated or hand-edited file reads as a complete one, and it
   collapses duplicate names into a dictionary, which makes `{"version":2,"version":1}` resolve
   to whichever copy the reader keeps — an ambiguous version is the same nondeterminism rule 2
   exists to remove. The scanner therefore rejects trailing commas, rejects a repeated name at
   any level (`.duplicateKey`), requires the whole input to be one complete value, forbids a raw
   control character inside a string, rejects ill-formed UTF-8 rather than substituting U+FFFD,
   rejects a lone surrogate, and stops at a nesting bound of 64 (`.tooDeeplyNested`) so a hostile
   document cannot exhaust the stack. Deciding control characters in the scanner rather than in
   `isValidTitle` matters: a title rejects them anyway, but a `path` has no character rule at
   all, so a syntax-level check is the only thing stopping `"a\0b"` from becoming a configured
   application path that reaches dispatch. The second property is numbers. The scanner keeps a
   number as its **exact literal text**, and `ExactJSONNumber` decides integrality on those
   digits with no floating-point step anywhere, because precision lost before the codec sees the
   token cannot be recovered after. So `1.0000000000000001` and `0.99999999999999999` are not
   version 1, `9007199254740993` is reported as itself rather than as `9007199254740992`, and
   `9223372036854775807` is an honest "your PhoneDeck is older than this file" instead of a
   claim that the file is corrupt. Exactly-integral spellings stay accepted — `1.0`, `1e0`,
   `0.1e1` and `1.5e1` (which is 15) — because JSON has one number type. An exponent too large to
   matter is **discarded, never truncated**: with `m` mantissa digits and `f` of them after the
   point, a nonzero value needs `E − f ≤ 18` to fit `Int.max < 10^19`, and needs `f − E < m` to be
   an integer at all, so every exponent outside `±(m + 19)` is provably out of range. The
   accumulator stops at that derived bound and the token is then decided by its mantissa alone —
   nil if nonzero, `0` if zero, since zero times any power of ten is zero. The bound is derived
   from the mantissa length rather than chosen, which is what makes it safe: freezing at a fixed
   magnitude and then carrying the frozen value into `E − f` let a huge exponent cancel a huge
   fraction, and `0.` followed by 999 999 zeros followed by `1e10000000` — exactly 10^9000000 —
   read as version 1. Large exponents that genuinely cancel stay accepted, so
   `1` followed by 1 000 000 zeros followed by `e-1000000` is still exactly 1; rejecting every
   large exponent would have hidden that defect rather than fixed it.
7. **The byte cap is one claim measured in both directions.** The decoder accepts a document
   only if the *canonical* form — pretty-printed with sorted keys, the one form the encoder
   writes — also fits the cap. Pretty-printing expands a compact document, so measuring the cap
   on the bytes as read let a configuration be valid on disk and impossible to save unchanged,
   which is exactly the silent-failure shape ADR-007 exists to remove. Both directions call the
   same `ConfigurationCanonicalForm` rather than the encoder calling the decoder and the decoder
   calling the encoder, so the size contract cannot drift and the two directions cannot recurse.

`ConfigurationError` cases carry no payload from the document — not even an offending key name —
so configuration content cannot reach a log line or an HTTP response by way of an error,
matching `ActionOutcome`'s rule. The single exception is `.unsupportedVersion(found:)`, where
the integer *is* the diagnosis. Document caps (1 MiB, 4096 controls) are corruption guards
rather than product policy: both are far above anything `POST /launcher` can produce under its
64 KiB body limit, and the 7-slot product limit stays in the client's `APP_SLOTS` until M2.5
makes it a writer-side rule. The 1 MiB cap is measured on the canonical form in both directions
(rule 7), so it bounds what can be *stored*, not merely what can be read.

Rejected alternatives: `Codable` (synthesized decoding ignores unknown keys, cannot express
absent-versus-malformed without re-implementing the state enum, and puts user content into
`DecodingError`); `JSONSerialization` **for reading configuration** — it remains the house idiom
for `launcher.json` and every API response, and this codec still uses it to *write* the canonical
form, but it accepts trailing commas, collapses duplicate names into a dictionary and hands back
numbers already widened to `Double`, none of which a caller can correct after the fact (rule 6);
a reserved opaque `layout` subtree (rule 1); path-derived control ids (rule 4); treating every
non-`1` version as "from the future" (rule 2); and measuring the byte cap on the document as read
rather than on the form the codec would write (rule 7).

**Consequences.** M2.4 delivers `Sources/oldphonedeck/Configuration.swift` as a pure codec plus
migration, and nothing else. It takes `ConfigurationInput` (`.absent` / `.unreadable` /
`.data`) rather than a `URL`, so it opens no file and its tests need no home-directory
isolation — which matters here, because `NSHomeDirectory()` ignores `$HOME` on this macOS
build. Absence and unreadability are distinct states that demand opposite responses: an absent
document may be created, an unreadable one must never be overwritten.

The codec is **not wired**: `Launcher`, `/launcher` and the client are untouched, `launcher.json`
stays on disk, and the ARCHITECTURE §9 finding that unparseable and absent are
indistinguishable *at runtime* remains open until M2.5. The module is also dead code in the
release binary until then, which is the deliberate cost of landing a boundary one milestone
ahead of the feature that uses it.

M2.5 owns storage integration, the read-path migration, any writer, the product-level control
cap, and the dual-write-versus-cutover decision — ADR-007 retains `launcher.json` until the new
format is proven on the physical device, and a binary downgraded after a V1 cutover would
otherwise read `nil` and show an empty deck. M3 owns `layout`, the V1→V2 migration and
data-driven rendering. Adding an action stays a deliberate code change, not configuration.

---

## ADR-016 — Configuration storage: an authoritative V1 file beside a frozen legacy file

**Status:** Accepted by Steering · 2026-11-07 · Target: M2.5. This **elaborates** ADR-007 and
ADR-015 and supersedes neither; both remain accepted and unedited. ADR-015 decided what the V1
document looks like. This record decides where it lives, when it may be replaced, and what happens
when a replacement cannot be completed. The consolidated design behind it is
`docs/M2.5-DESIGN.md`; the drafting record is `docs/M2.5-ADR-016-DRAFT.md`.

**Context.** ADR-015 delivered a V1 codec that is deliberately unwired: `Launcher.selected()` still
reads a bare array from `launcher.json` and returns one `nil` for an absent, an unreadable and an
unparseable file alike, so the ARCHITECTURE §9 finding stays open. Four constraints shape the
storage layer. Converting `launcher.json` in place is impossible: a pre-M2.5 binary casts it
`as? [String]` (`Control.swift`), so a V1 object yields `nil` and a downgraded install silently
shows an empty deck. Permanent dual-write is impossible: a bare array cannot express a title, a
custom id or `.unmodeled` parameters. `NSHomeDirectory()` ignores `$HOME` on this macOS build, so
storage cannot be isolated by environment and cannot be tested without an injected directory. And
the ES5 client abandons a non-200 `GET /launcher` (`web/index.html`), so a degraded state answered
with an error status renders as exactly the silent empty deck ADR-007 exists to remove.

**Decision.** Storage is two files in one directory. `config.json` holds the V1 document and is
authoritative. `launcher.json` is **frozen**: read-only, never written, never deleted, and
consulted only when `config.json` is absent. Fourteen rules carry the weight.

1. **Source-aware shapes.** `config.json` must contain a V1 object and `launcher.json` must contain
   a legacy array. A well-formed document in the wrong file is `wrongFormat` — reported, never
   adopted, never overwritten, never reinterpreted. Source-awareness is a store-level interpretation
   layered over the unchanged codec, so `Configuration.swift` gains no lines.
2. **Distinguishable outcomes replace one `nil`.** Ready, over-limit, unprojectable, unconfigured,
   migration-pending, legacy-unrepresentable, damaged (malformed / unsupported-version / unreadable
   / non-regular), wrong-format, corrupt and busy. A document that cannot be expressed as a path
   list yields `selected: null`, never a partial projection.
3. **A valid legacy file that cannot be migrated is served, not hidden.** Its selection is still
   rendered; the state is read-only and writes are refused, because replacing a large legacy
   selection with the seven keys the page could show would destroy preserved data, and because a
   legacy write path would be a second writer.
4. **Readers never lock; writers always do.** `rename(2)` gives atomic visibility, so a read needs
   no coordination. Every write — including migration-on-read, which ADR-007 places on the read
   path — holds one exclusive advisory lock on a separate `config.lock` file, whose inode survives
   the target's replacement.
5. **Migration is double-checked under the lock.** State is re-read after acquisition; a migration
   commits only if `config.json` is still absent, and adopts the winner's document otherwise. A
   stale migration can therefore never overwrite a concurrent save.
6. **No write may block the shared HTTP queue.** The lock is non-blocking and never waited on:
   contention returns `503` for a write and a read-only response for a migration, because that queue
   also carries MJPEG delivery.
7. **Lost updates are refused by an opaque revision token, not by comparing file bytes.**
   `GET /launcher` publishes a `revision` fingerprinting the configuration *content* the client
   observed, and `POST /launcher` must echo it as `expected`. The server recomputes it under the
   exclusive lock and refuses a mismatch with `409 stale` and an absent token with
   `400 missing-revision`. Comparing bytes across one request's own classification window is not
   sufficient: the window that matters is the browser's, between its GET and its POST.
8. **Three-phase commit.** Pre-commit validation is the writer's policy bounds plus
   `ConfigurationEncoder.verifiedData`. Atomic replacement is a `mkstemp` temp in the target's own
   directory, `fchmod 0600`, `fsync(fd)`, `rename`. **File-data synchronization is pre-commit and
   fatal.** **Directory synchronization is post-commit and best-effort:** `fsync(dirfd)` is
   attempted, any errno is swallowed, and a save is never failed for it, because macOS guarantees no
   directory-`fsync` semantics and `F_FULLFSYNC` on a directory fd returns `EINVAL`. The behaviour is
   measured on the target build rather than assumed. Post-commit verification re-reads, re-decodes
   and requires equality with the intended value.
9. **One retained generation, replaced safely.** A previous generation is retained as
   `config.json.prev` by hard link — one directory entry, no data copy, safe precisely because writes
   never mutate in place — with a copy fallback where `link(2)` is unsupported. **The replacement is
   prepared under a temporary name and swapped in by `rename` before the commit, so an existing
   backup remains visible and byte-intact until its successor exists; a backup is never unlinked
   before the generation it will replace has been captured.** Recovery restores from the base bytes
   captured under the lock, not from the backup, so it cannot restore a generation older than the one
   the client's revision described. If restoration also fails, neither file is deleted. **An initial
   migration has no previous generation: a failed verification is reported as `migration-failed`,
   the damaged document is retained as evidence, the state becomes read-only, and it is never
   reported as a successful migration.** Its recovery is the frozen `launcher.json`, byte-intact
   precisely because migration never writes it — the only case in which the legacy file is a
   recovery path.
10. **Durability is `fsync`, not `F_FULLFSYNC`.** Atomic visibility and power-loss durability are
    distinct claims: the rename guarantees the first, and `fsync(fd)` before it is what makes the
    second as strong as macOS offers without forcing a device-cache flush on the serial HTTP queue.
    An acknowledged save can still be lost on power failure, and the frozen `launcher.json` does not
    recover any edit made after migration.
11. **Preservation is not authorization.** The write path performs no `Apps.isKnown` filtering, so
    an uninstalled app's path, an empty path and a duplicated path survive a save. Storage confers
    nothing: `ActionRegistry.dispatch` re-validates and re-authorizes against the Mac's own catalog
    on every launch, and `.unmodeled` parameters remain inconvertible. A save is refused outright
    when `legacySelection` is `nil`, **or when the document holds more controls than the writer's
    limit of seven**, because a path list cannot reproduce a document that has titles, custom ids or
    unregistered actions, and because the ES5 editor truncates the selection to `APP_SLOTS` on load
    and would silently discard every control past the seventh. **Such a document is served in full —
    all N paths on the wire — and marked read-only; the client truncates for display only, and the
    server never truncates on disk.**
12. **The revision is a concurrency control, not an integrity control.** It is a 64-bit
    non-cryptographic fingerprint, opaque to the client, identifying configuration *content* rather
    than file bytes. Two consequences are intended: a whitespace-only hand edit does not invalidate
    a client, and **migration does not invalidate a client either**, because the bytes a commit
    writes are exactly `ConfigurationCanonicalForm.data(c)` — the same `Data` the pre-migration
    fingerprint was taken over, since `verifiedData` returns it unchanged. A client holding the
    access token can always obtain a fresh revision and write anything; the token exists to stop an
    accidental stale overwrite, which is why cryptographic strength is not purchased with a new
    framework dependency.
13. **The request contract names its own length.** `POST /launcher` carries `n`, the selection
    count, alongside `paths`, because `paths` alone cannot distinguish an empty selection from a
    selection holding one empty path — both encode to `""`. For `n >= 1` agreement is structural:
    splitting without omitting empty subsequences yields exactly `newlineCount + 1` elements, so
    `n = 1` with an empty `paths` **is** the one-empty-path case and must be accepted. Only `n == 0`
    needs its own rule. A disagreement between `n` and the parsed elements is a `400`, never a silent
    truncation or padding. A request without `n` is parsed with the pre-M2.5 rule, so an old
    client's behaviour is unchanged.
14. **`POST /launcher` returns the `GET /launcher` shape.** One response shape for both methods,
    plus `saved`, so the client replaces its state wholesale and the application catalog it renders
    from cannot be dropped by a save; and plus `revision`, so a second edit needs no intervening
    GET. Error bodies are single fixed lowercase tokens in the existing `text/plain` style of `ok`
    and `unknown app`, drawn from the same server-authored table as the `configuration` field;
    exactly one status-reason map entry, `409`, is added, and `412`/`428` are not introduced where
    the existing vocabulary already represents the case.

The writer enforces the product cap of seven application controls, which ADR-015 explicitly
deferred to this milestone; the codec's 4096 remains a corruption guard. `GET /launcher` keeps
returning `200` in every degraded state and adds `configuration`, `version`, `writable` and
`revision`. A new `--config-dir` option redirects the token, the configuration files and `tls/`; it
does not redirect the application catalog, and it is what makes storage acceptance-testable given
`NSHomeDirectory()`'s behaviour. Reads use `O_NOFOLLOW` and `O_NONBLOCK` with an `fstat`
regular-file check and a bounded read, so a symlink fails closed, a FIFO cannot block the shared
queue, and an oversized file is rejected without being allocated. Temporary files come from
`mkstemp`, are `fchmod`'d to `0600`, live in the target's own directory, are owned and unlinked by
the process that created them, and are never swept by a startup glob that could delete a live
instance's in-flight temp.

**Consequences.** A downgrade after cutover restores the *pre-migration* selection, cannot see
later edits, and is not prevented from rewriting `launcher.json`; that cost is disclosed, rehearsed
in the cutover protocol, and accepted rather than mitigated, because mitigating it would mean
writing `launcher.json` again.

An already-loaded pre-M2.5 page can still read the deck but **can no longer save**: its POST
carries no `expected` and is refused with `400 missing-revision`, failing loudly in a client that
only ever showed "Save failed". One page reload, which `Cache-Control: no-store` guarantees fetches
the new client, resolves it, and the cutover procedure includes that reload. This is the one
user-visible regression M2.5 introduces, and it is a refusal rather than a loss.

Removing the save-path filter narrows a defense-in-depth control recorded in ARCHITECTURE §9 — an
inert path may now be stored — and is accepted because execution authorization is unchanged and is
the control that matters. Populating `all` in the save response costs one catalog scan, which the
save path already performed for the filter rule 11 removes, so the cost is net unchanged. The
revision adds one canonical re-encode per configuration read, bounded by the 1 MiB cap.
`config.json` is `0600` where `launcher.json` was `0644`. One retained generation means two
consecutive failed saves can lose a good document. A crash between the backup swap and the commit
leaves `.prev` duplicating `config.json`, and distinctness returns on the next successful write. A
leaked temp file after a crash is inert garbage that no code path reads.

Wiring the route requires extracting a shared `LauncherRoute.handle` from `main.swift`'s top-level
closure, following the `AppLaunchRoute.handle` pattern M2.3 established, because top-level code is
unreachable from a test target. M3 owns `layout`, the V1→V2 migration, data-driven rendering and
the removal of the client's own `APP_SLOTS` constant.

**Rejected alternatives.** Converting `launcher.json` in place. Permanent or conditional
dual-write. Migrating at startup instead of on read (contradicts ADR-007, and makes a process's
first act a disk mutation nobody requested). Adopting a well-formed document found in the wrong
file (creates two sources of legacy truth with undefined precedence when both hold arrays). A
revision field inside the V1 document (requires changing an accepted, closed codec, and ADR-015
rule 1 rejects unknown keys). Comparing `config.json` bytes across the request's own lock window. A
revision counter in a sidecar file (a second file to commit atomically, and it can desync). A
cryptographic revision digest. `412`/`428` statuses where `409`/`400` already denote the cases. A
JSON error body on a route whose every other error is plain text. Omitting `all` from the save
response. Inferring the selection count from a mandatory trailing separator (a client that forgets
the terminator silently loses its last entry, where `n` turns the same mistake into a `400`).
Repeated `paths=` fields (`HTTPRequest.params` is a dictionary, so repeats collapse). Unlinking the
old backup before creating the new one. Recovering from `.prev` rather than from the base captured
under the lock. Committing before swapping the backup. Treating a failed directory `fsync` as a
failed save. Serving a truncated selection for an over-limit document. PID-derived temp names and a
glob-based startup sweep. Memoizing the document in memory (cross-process staleness the stateless
read path does not otherwise have). Blocking on the lock. `F_FULLFSYNC` per save.

---

## Implementation note — ADR-016 / M2.5 S1

**Current status (2026-11-08): M2.5 COMPLETE; S1–S7 accepted by Steering** on
`m2.5/s1-configuration-store` (S4 code: `d0d8747`). The store is wired into GET/POST `/launcher`
and the ES5 client consumes state and revisions. Steering confirms production migration/cutover,
rollback rehearsal, production authentication rotation and physical iPhone 11 acceptance **PASS**.
New authenticated access works on that device; the previous token is rejected. Phase A is complete;
Phase B records these results for GitHub consolidation without further production operations.
ADR-016 and all other approved ADR decisions remain accepted as originally recorded.

**S1 delivery history:** S1 introduced `Sources/oldphonedeck/ConfigurationStore.swift` unwired;
at that slice the legacy `Launcher` remained the runtime path, the codec and endpoints were
unchanged, and every test owned a temporary directory. S3 later activated the store and S4 the
revised client on the feature branch; neither constitutes production deployment. The store's
injected directory remains necessary because `NSHomeDirectory()` does not follow `$HOME` here.

What exists: source-aware classification into ten states; bounded `O_NOFOLLOW | O_NONBLOCK` reads
with an `fstat` regular-file check and a cap-plus-one byte limit; the canonical-content revision
fingerprint; non-blocking `flock` on a separate `config.lock` held across the whole
read-modify-write including a double-checked migration-on-read; the three-phase commit with the
backup prepared under a temporary name and swapped in before the commit; recovery from the base
bytes captured under the lock; and a per-step filesystem seam that makes every failure point
injectable.

Evidence at S1: **319 Swift Testing tests in 36 suites pass** (the 248 retained M2.1–M2.4 tests
plus 71 new ones in 7 new suites), `swift build -c release` completes with **zero warnings**, and
**eight gate mutations** — removing the seven-control writable gate, moving the backup swap after
the commit, dropping the in-lock migration re-check, skipping post-commit verification, dropping
`O_NOFOLLOW`, fingerprinting raw bytes instead of canonical content, accepting a missing revision,
and accepting a stale revision — were each observed to turn the relevant tests red and were reverted
from a backup verified byte-identical by SHA-256. One mutation in the first round was ineffective
rather than caught: it removed a comparison that an earlier `guard let` already made unreachable,
and was replaced by one that removes the gate where it actually is. **No physical-device acceptance
is claimed or possible for S1** — no endpoint or client behaviour changed.

Two findings surfaced while implementing, both recorded rather than worked around, because working
around either would mean changing `Configuration.swift` or adding a second parser:

- A legacy array with more entries than `ConfigurationDecoder.maximumControlCount` (4096) is
  rejected by the codec's corruption guard **before** migration can run, so it reports `malformed`
  with `selected: null` rather than `legacy-readonly` with its selection served. Rule 3's promise
  therefore holds only for legacy files the decoder accepts. The reachable shapes of
  `legacyUnrepresentable` are an entry longer than 4096 bytes and a canonical form over 1 MiB.
- A legacy file with more than seven entries migrates faithfully and lands in `overLimit`, so it
  becomes read-only immediately after migration. That is rule 11 working as intended, but it means
  a hand-edited legacy selection above seven keys can be seen and used, and not edited, until it is
  reduced by hand.

Nonblocking documentation debt carried forward: `AGENTS.md` §2 still has no `Configuration.swift`
row and now also needs one for `ConfigurationStore.swift`. That file is protected against agent
edits in this workflow, so both rows need a human edit. `docs/ARCHITECTURE.md` §3 carries the
equivalent rows.

---

## ADR-017 — Two configurable widgets in Configuration V2

**Status:** Architecture approved by Steering · 2026-11-08 · Target: M3.2.1.
Implementation acceptance and production cutover remain separate decisions. This extends
ADR-010/015/016; the accepted V1 rules remain the rules for V1 documents.

**Decision.** `config.json` now supports the strict V2 shape
`{"version":2,"controls":[…],"widgets":{"internet":true,"batteries":true}}`.
The complete V1 controls schema is reused unchanged. Both widget keys are required JSON
booleans; unknown keys, duplicate names, malformed input and unsupported versions fail closed.
The existing strict scanner, exact-number handling, canonical byte cap and verified encoding
apply to both versions. Preferences describe visibility and grant no execution authority.

V1→V2 copies every control, identity, order, parameter and title, without catalog filtering,
normalization or reconstruction from paths. Both widgets default to visible. Promotion happens
on read, with the existing non-blocking lock, locked re-read, atomic replacement, retained base,
post-commit equality check and verified recovery. A valid V1 whose expanded V2 exceeds the cap
remains untouched and read-only (`unrepresentable`). Over-limit and metadata-bearing documents
can migrate losslessly but remain read-only in the path-list editor. Legacy arrays migrate to
V2 through the existing lossless V1 conversion; `launcher.json` stays frozen.

Before replacing an existing V1, the store retains its **byte-exact** first generation as
`config.json.v1`, independently of rotating `config.json.prev`. It writes and syncs a 0600
temporary, publishes it with a no-replace hard link and verifies its bytes. An existing valid
V1 snapshot is never overwritten; malformed, unreadable or non-regular snapshot paths block
promotion. Filesystems unable to publish this snapshot safely also block promotion. Subsequent
V1 bases are retained by `.prev`, while `.v1` continues to identify the first cutover generation.

GET and successful POST `/launcher` share the existing response plus `widgets` (two booleans,
or `null` if preferences cannot be determined). Ready V2 reports `configuration: "v2"`;
successful migration reports `migrated`. Status/refusal behavior otherwise remains unchanged.
Revisions fingerprint the entire canonical V2 denotation, so controls and widgets share one
concurrency boundary and V1/legacy promotion does not invalidate a revision issued by this build.
A previously loaded M3.1 page may receive `409 stale` after promotion and must reload.

POST accepts form fields `internet` and `batteries`: both absent preserves current flags;
both present requires exactly `0` or `1`; partial/invalid pairs return `400 invalid-widgets`
before any store operation. With both flags present and both `n` and `paths` absent, only
widgets change; otherwise existing selection parsing applies. Changes are assembled from the
locked current document after the revision check. Visibility-only writes preserve controls;
application-only writes preserve flags. The existing read-only guard refuses all writes to
unprojectable metadata rather than flattening it. No endpoint, action type, execution path,
framework or dependency is added; `ActionRegistry` remains the app execution authority.

The existing ES5 long-press editor gains two labeled checkboxes and retains Save/Cancel.
Preferences apply only after successful Save, persist on the Mac, and survive browser and
Home Screen storage separation. A fixed two-entry descriptor list controls `display` only;
geometry, polling, music, app keys, Claude, Phone and status remain unchanged. A new page
without a widget-capable server response fails closed for saving. Broader ADR-010 layout work
and generalized widget/plugin systems are outside this slice.

**Rollback.** No automatic downgrade, `.prev` adoption or legacy fallback is introduced.
M3.1 reports V2 as `unsupported-version` and refuses saves. The pure, explicit
`ConfigurationMigrator.exportV1` validates V2 and returns a verified V1 encoding of **all latest
controls**, including custom IDs, titles and inert unknown-action parameters; only widget
preferences are intentionally omitted. Export is not a new HTTP operation.

For a separately authorized deployment, first preserve an operator-owned byte-exact V1 snapshot
outside the live directory and verify the six current selections; the runtime `.v1` snapshot is
an additional safeguard, not permission to inspect production during implementation. For a
separately authorized rollback: stop V2 writers, retain the latest V2 bytes, export and validate
latest controls, atomically restore the verified V1 as `config.json`, then start M3.1 and reload
the iPhone page. Verify all six selections and launch boundaries. A valid metadata-bearing V1
remains read-only in M3.1, as before. Restoring the initial `.v1` snapshot instead loses later
app edits and is an explicit recovery choice, never the default latest-controls rollback.
Neither export nor restoration is performed on production in M3.2.1.

**Validation gate.** Strict codec, four visibility combinations, complete metadata migration,
wire refusal/no-write behavior, cross-field preservation, stale/concurrent writes, failed-write
recovery, snapshot retention and rollback must pass in isolation, alongside ES5 parsing,
browser interaction checks, relevant regressions and a warning-free release build. One focused
independent review covers codec/store/wire integrity and rollback. Physical iPhone 11 acceptance
must verify Save/Cancel, all four combinations and re-enable, reload, server restart, Home Screen,
portrait/landscape and existing apps/Claude/media/Phone/status. Automated browser checks do not
establish physical acceptance. No production deployment or merge is authorized by this ADR.

## ADR-018 — Explicitly approved UUID Shortcuts and complete-control editing

**Date:** 2026-11-09. **Status:** implementation authorized by Steering; independent
review and physical iPhone 11 acceptance are separate gates. Base: `96c637f84bfaf5872173b440178459906c7eda43`.

**Evidence and scope.** Steering reports that the harmless PhoneDeck M3.3 UUID Test
resolved by UUID through `/usr/bin/shortcuts run`, exited 0 after 13.654 seconds and
printed `PhoneDeck UUID proof`. Apple's engine showed an output-sharing consent prompt;
Allow Always resolved it. This proves Terminal UUID execution only. It does not prove
unattended execution in the server context. No real Shortcut run is authorized by this ADR.

**Authority.** `shortcut.run` is registered alongside `app.launch`. The action boundary
accepts a strictly typed UUID and consults the server-owned `ShortcutService`. The private
`shortcut-approvals.json` array contains only UUID/display-label pairs, is loaded at server
startup from `--config-dir`, and defaults to no approvals. The file must be a regular,
non-symlink, singly linked file owned by the current user with no group/other access,
limited to 16 KiB and 16 unique entries. Invalid input closes all approvals. Labels are
bounded display data. Neither discovery, configuration nor HTTP can add approvals.
Personal identifiers/approvals stay outside Git; the filename is ignored defensively.
Only the explicitly approved harmless test belongs in the isolated preview.

**Execution.** The authenticated `POST /shortcut` accepts `uuid`, and returns a server-issued
run ID immediately; `GET /shortcut?id=…` polls the latest run. Both use existing header
admission, token scope, body deadlines and shared connection budget. POST is capped at
1 KiB; GET has no body. The registry rejects unapproved identifiers before reserving any
process. One shared slot spans a fresh, read-only `/usr/bin/shortcuts list --show-identifiers`
lookup (five-second bound) and the authorized `/usr/bin/shortcuts run UUID` (30 seconds).
Names never enter an execution argument. Foundation Process uses a fixed executable and
fixed argument forms, null-device stdin, nonblocking bounded stdout/stderr drainage, at
most 64 KiB retained stdout, and a dedicated asynchronous queue. Output and consent details
are never returned to the phone. No shell, arbitrary options, queue or automatic retry exists.
A timeout publishes UNKNOWN side-effect outcome immediately, sends SIGTERM and escalates
to SIGKILL after 500 ms. The slot remains held until the owned CLI exits and handles close.
Terminating that CLI cannot guarantee Apple's external engine or effects were cancelled.
Completed means CLI exit 0, not independently verified effects. Status retention is bounded
to the latest run; missing/network-lost status also means unknown outcome, never a retry.

**Configuration integrity.** Configuration V2 remains the format. `POST /launcher` may send
`controls` as a complete strict-codec JSON array with `expected` revision and optional paired
widget flags. `controls` cannot be mixed with legacy `n`/`paths`. The store validates and
commits the complete ordered controls under its existing nonblocking lock, revision,
atomic verification and recovery path. Unknown actions and their flat parameters, custom
IDs, labels, missing applications and unapproved Shortcuts are preserved as data and remain
inert unless separately authorized. Shortcut configuration retains flat `uuid` parameters;
only dispatch constructs `ShortcutUUID`. Saving a document never dispatches it.
Legacy application-only writes still refuse mixed/metadata-bearing documents. The response
adds complete `controls`, `controlsWritable` and an approved-only `shortcuts` catalogue;
legacy `selected`/`writable` keep their original path-projection meaning.

**Client.** The existing ES5 editor displays configured entries first in exact order, then
available Mac apps and approved Shortcuts, using server labels through `textContent`.
Seven positions remain; a full selection requires a removal before an addition. Reordering
moves whole controls; unchanged controls retain their IDs, parameters and presentation.
Unavailable/inert entries remain visible in place. Save/Cancel, revisions, widgets and key
rendering are reused. New IDs are chosen without colliding with the draft. Nothing changes
the user's existing seven application selections until an explicit editor Save.

**Consent and acceptance.** See `docs/M3.3-SHORTCUTS.md`. A separately authorized real
server-triggered test must use the intended binary, login session and launch context, with
human handling of any macOS consent. Terminal's Allow Always is not inherited evidence.
Builds and tests use fakes. Production changes, merge and acceptance remain unauthorized.


## ADR-019 — Native user-session startup and fail-closed recovery

**Status:** M5.1 candidate; pending Steering acceptance · 2026-11-10

Steering authorized evaluating a native user LaunchAgent for reliable login startup,
without a new architecture. Run the existing sandboxed Swift binary directly in Aqua,
with RunAtLoad, unsuccessful-exit KeepAlive and a 30-second throttle. This is a narrow
exception to the former manual-only launch procedure, not a new supervisor. The logged-in
user session remains necessary for Mac integrations. LaunchDaemon/root operation and a
custom supervisor are rejected. Production remains on its existing launch until accepted.

Managed startup requires existing V2/token/TLS, matching LAN address, a lifetime kernel
lock and free required ports. Required listener failure exits for native restart; missing
state never triggers credential/TLS generation or an HTTP-only fallback. Changed LAN/TLS
requires separate authorized recovery. Preserve production sandbox restrictions, ports,
seven controls, widgets and Shortcut approvals. Do not prompt for Accessibility on an
unattended launch. Existing permissions and physical behavior remain separate acceptance.

Use launchd state plus a private stderr log for diagnosis, with raw stdout discarded to
avoid the legacy credential banner. Loaded/listening does not prove authenticated service
health. The generator stages artifacts only; identity checks, current-state backups,
explicit production cutover approval and authenticated HTTP/HTTPS/WSS checks remain gates.
Full procedure and evidence: `M5.1-STARTUP.md`. M4.1 remains deferred and unchanged.
