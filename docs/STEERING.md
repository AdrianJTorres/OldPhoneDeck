# STEERING.md — PhoneDeck project charter

Canonical charter for PhoneDeck. If a proposal conflicts with this document, the
document wins until Steering amends it. Operational rules for agents live in
`AGENTS.md`; architectural facts in `docs/ARCHITECTURE.md`.

Status: **living document**, owned by Steering, revision 1 (2026-11-03).

---

## 1. Why PhoneDeck exists

An old iPhone is still a bright, always-on, touch display with Wi-Fi and a browser.
A Mac on the same desk has apps, media, builds, tests, Git state and AI agents running
on it, but no cheap physical surface to touch them.

PhoneDeck turns that spare phone into a dedicated control surface and status display
for the Mac — no jailbreak, no App Store, no client to install: Safari renders a page
served by the Mac itself.

The project exists because the combination is unusually cheap and unusually useful:
one small Swift binary, one HTML file, one phone that would otherwise be in a drawer.

## 2. Hardware roles

### iPhone 11 — primary interactive control surface

The iPhone 11 is the **main** device: the one the project is designed around, the one whose
behaviour is verified end to end, and the one that must work every day.

- Landscape and portrait layouts, Home Screen installation, full-screen standalone mode.
- All interactive controls: keys, media transport, notes into Claude, developer actions.
- Physical-device acceptance testing for every milestone that changes the UI happens
  on this device.

### iPhone 7 Plus — future information / dashboard role

The iPhone 7 Plus is **intentionally reserved** for a later information/dashboard role and
is not a target for current work. Its intended role is an always-on dashboard: status,
telemetry and read-only information, rather than fast interactive control.

This is a **product and design prioritisation, not a capability judgement**. The 7 Plus is
not excluded because it cannot run secure browser features; it is a scope decision — one
device must be the design and acceptance target, and a large always-on screen suits a
passive display better than rapid touch interaction.

- Large screen, always-on, low interaction frequency.
- No milestone before V1 depends on it.
- Any work on it must not complicate the iPhone 11 primary path.

Nothing in the current architecture is designed for two devices simultaneously; see
`docs/ARCHITECTURE.md` §10 for the limitations that would matter.

## 3. Project goals

1. A phone on the desk reliably controls the Mac: launch apps, media, capture a note.
2. The Mac's state is visible at a glance: network, batteries, media, and — over time —
   Git and agent status.
3. The surface is **configurable** without editing code: what the keys do, in what order.
4. Actions are **explicitly approved** on the server, never arbitrary commands from a
   browser.
5. The whole thing keeps building and running with one command on a Mac with no IDE.
6. Every milestone is verifiable on the physical iPhone 11.

## 4. Non-goals

- Not a general remote-desktop or VNC replacement.
- Not an internet-exposed service. No port forwarding, no tunnels, no cloud relay.
- Not multi-user, not multi-tenant, no accounts, no sync.
- Not a cross-platform product. macOS only.
- Not an App Store app; not an iOS client; no Xcode project, no code signing workflow.
- Not a rewrite of OldPhoneDeck, and not a framework for building control panels.
- Not a place for arbitrary shell execution triggered by a browser.
- Not a dependency-heavy stack, and not a place to "modernise" the frontend for its own sake.

## 5. Architecture philosophy

- **Small and boring.** One Swift executable, one HTML file, standard library and
  system frameworks. Boring is a feature: it survives months of neglect.
- **Incremental evolution.** OldPhoneDeck is the base. Add seams where features will
  attach; do not rebuild what already works.
- **Server-authoritative.** The Mac decides what may happen. The phone is a remote
  control, never a trusted peer.
- **Allowlists over validation-by-convention.** A path or action is executable only if
  it appears in a list the server itself produced.
- **Compatibility is a constraint, not a target.** The page must keep running on iOS 8/9
  Safari, because that is what makes the "old phone" premise true.
- **Documented boundaries before features.** Boundaries that features will depend on are
  introduced deliberately, one milestone ahead, not discovered mid-feature.

## 6. Hybrid Coding AI workflow

Work is routed by difficulty and risk, not by preference.

| Tier | Nature of work | Agent |
|---|---|---|
| T1 | Small, well-scoped, low-risk changes | Qwen Code |
| T2 | Multi-file implementation inside an approved design | Qwen Code |
| T3 | Security-sensitive, architecture-sensitive, or hard-to-diagnose work | Codex |

- **Qwen Code** is the primary implementation agent: repository analysis, routine
  terminal work, scoped implementation, verification, documentation.
- **Codex** handles T3 work and performs **independent review** of work it did not
  author, especially anything touching authentication, ingress, action authorization,
  TLS, or process execution.
- **Steering** (the human project owner) holds architecture and scope authority:
  decides milestones, accepts or rejects architectural changes, ratifies ADRs.
- **The human does not execute routine terminal commands.** Agents do. Human
  intervention is reserved for what an agent cannot do: macOS permission dialogs,
  credentials, physical-device checks, and decisions.
- **One WRITE_OWNER per branch/worktree.** Everyone else is read-only on that branch.

See `docs/DECISIONS.md` ADR-011 to ADR-013.

## 7. Milestone governance

1. Steering defines a milestone as a bounded brief with an objective, explicit tasks,
   an explicit list of things **not** to do, and success criteria.
2. The agent executes only that milestone. Findings outside scope are **recorded**, not
   fixed.
3. A milestone closes only when its success criteria are demonstrated — build output,
   endpoint behaviour, and where relevant a check on the physical iPhone 11.
4. A milestone does not begin until its predecessor is accepted by Steering.
5. Architectural change requires an ADR **and** explicit Steering acceptance. It is not
   a side effect of an implementation task.
6. Documentation is part of the milestone, not an afterthought: a milestone that changes
   behaviour updates `docs/ARCHITECTURE.md`, and a milestone that changes a boundary adds
   an ADR.

## 8. Definition of V1

V1 is reached when, on the physical iPhone 11, a user can:

1. **Control** — launch configured apps and macOS Shortcuts from keys whose content and
   order they configured on the device, without editing code or config files by hand.
2. **Capture** — dictate or type a note that opens a new Claude conversation on the Mac.
3. **Observe** — see media state, network, batteries, and Git/agent status for an
   allowlisted repository.
4. **Operate safely** — every action available to the phone is explicitly allowlisted on
   the Mac; no endpoint can execute an arbitrary command.
5. **Recover** — start the whole system with one documented command after a reboot, and
   reinstall to the Home Screen from documented steps.
6. **Trust the boundary** — authentication, ingress limits and action authorization have
   been independently reviewed (Codex, T3) and the known HIGH risks recorded in M1 are
   resolved or explicitly accepted.

V1 is not defined by feature count. It is defined by those six properties being true
and demonstrable.

## 9. Current status (2026-11-09)

| Milestone | State |
|---|---|
| M0 — Baseline verification | **COMPLETE** — fork created, clone configured, baseline `e622184` builds and runs, verified on the iPhone 11 |
| M1 — Understand & document | **COMPLETE** — M1.1 repository analysis and M1.2 project documentation both reviewed and accepted by Steering |
| M2 — Foundations | **IN PROGRESS** — M2.1–M2.4 accepted by Steering; ADR-015 and ADR-016 remain ratified. **M2.5 COMPLETE (2026-11-08)**: S1–S7 accepted; production migration/cutover, rollback rehearsal, production authentication rotation and physical iPhone 11 acceptance PASS. New authenticated device access works and the previous token is rejected. Phase A is complete; Phase B GitHub consolidation is submitted for Steering acceptance without merge or branch deletion. |
| M3 — PhoneDeck UI | **IN PROGRESS** — M3.1 production accepted at `14872a3a`; M3.2.1 physical iPhone 11 acceptance PASS confirmed on 2026-11-09, independent review PASS and 405 automated tests PASS. **M3.3 functional and physical iPhone acceptance PASS**, accepted by Steering on 2026-11-09 at `873848566503e169ec98cfbd228c5e4ba98ac851`; one independent T3 review with focused closure PASS. M3.3 is **COMPLETE**, merged to `main` at `c3fdff8906f88decfd8fdde4335d8bad17df953f`, deployed and physically accepted on iPhone 11, as confirmed by Steering on 2026-11-09. **M3.4 COMPLETE — implementation and physical iPhone 11 acceptance PASS**, confirmed by Steering on 2026-11-09 for `46133b6b0b36daf9ce9898297d11523034e06c60`, focused independent review PASS. GitHub integration via [PR #10](https://github.com/AdrianJTorres/OldPhoneDeck/pull/10), using a merge commit; this record takes effect with that merge. Production remains unchanged; M3.4 deployment is not authorized. Overall M3 production closure remains with Steering. |
| M4 — Developer Deck | Not started |
| M5 — Security & reliability | Not started |
| M6 — PhoneDeck V1 | Not started |

Physically verified on the iPhone 11: Safari loads the deck, Home Screen installation
works, Mac application control works, Spotify control works. **M2.5 physical iPhone 11 acceptance
PASS**, confirmed by Steering on 2026-11-08, including new authenticated access after production
rotation. No separate physical-device acceptance is claimed for the unwired M2.4 or M2.5 S1 slices.

Known risks carried forward from M1 are recorded in `docs/ARCHITECTURE.md` §9, together
with the milestone that owns each one. They are **open**, not fixed. M2 delivers the
minimum ingress hardening and the allowlisted action boundary; M5 performs the independent
review and the remaining hardening. The absent/unparseable configuration finding is **closed**:
M2.5 wires the codec/store distinction into the read path and client, and production cutover is
accepted. The remaining M5 risks stay open.

M3.3 acceptance evidence: execution and completion of the harmless UUID test from the isolated
iPhone 11 preview on port 8077 are verified. The user observed Completed without a consent
dialog; the Text-only test need not cause visible Mac activity. Three CLI executions were
observed, and the user reports very likely three key presses. Exact HTTP request-to-process
correlation is unavailable; no automatic-duplication defect is proven. Steering lifted that
blocker and accepted M3.3 functional and physical behavior. Focused dispatch checks confirm
one request per tap, no automatic retry, concurrent execution rejection, timeout-unknown
preservation and the CLI exit-0 completion gate. The existing 422-test baseline, 33 focused
client/launcher tests, warning-free release build and independent review are retained; only
the missing browser touch regression used new fake responses. No real execution or broad
review/test repetition was part of consolidation. Steering subsequently confirmed M3.3 merged,
deployed and physically accepted on iPhone 11 (2026-11-09). This status update records that
human acceptance; it does not claim new automated or physical checks. M3.4 implementation and
physical iPhone 11 acceptance are also PASS, as confirmed by Steering. Publication and merge
are authorized for PR #10; production deployment is excluded. Stop for Steering after GitHub
integration verification. See ROADMAP's M3.3 entry for the evidence boundary.
