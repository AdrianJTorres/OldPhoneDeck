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
belong to M2.2, the Action boundary remains pending, and the M5 independent assessment is
still outstanding.

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

**Status:** Implemented on `m2.3/app-action-boundary`. **Pending independent review and
Steering acceptance** — not accepted, not merged. M2 as a whole remains IN PROGRESS.

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
