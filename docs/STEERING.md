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
2. **Capture** — Claude-dependent note capture is **not a verified V1 capability**. The user
   does not use it; the fixed entry becomes Configure. Legacy backend compatibility remains;
   a future capture workflow requires a separate Steering decision.
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

## 9. Current status (2026-11-10)

| Milestone | State |
|---|---|
| M0 — Baseline verification | **COMPLETE** — fork created, clone configured, baseline `e622184` builds and runs, verified on the iPhone 11 |
| M1 — Understand & document | **COMPLETE** — M1.1 repository analysis and M1.2 project documentation both reviewed and accepted by Steering |
| M2 — Foundations | **IN PROGRESS** — M2.1–M2.4 accepted by Steering; ADR-015 and ADR-016 remain ratified. **M2.5 COMPLETE (2026-11-08)**: S1–S7 accepted; production migration/cutover, rollback rehearsal, production authentication rotation and physical iPhone 11 acceptance PASS. New authenticated device access works and the previous token is rejected. Phase A is complete; Phase B GitHub consolidation is submitted for Steering acceptance without merge or branch deletion. |
| M3 — PhoneDeck UI | **COMPLETE — production accepted by Steering** at `dc9133701d9106cc7c6dec8caae3bd2bfc53c54a` (M3.4 / PR #10). Seven controls, V2 configuration, widgets, authentication/TLS and empty Shortcut approvals remain accepted. Claude-dependent note capture is not a verified V1 capability. |
| M4 — Developer Deck | **M4.1 DEFERRED TO M5**: implementation `8a65c7bc88fecbe831cd2f1890d1486ed578e049`, independent focused review and physical iPhone 11 acceptance PASS; production integration blocked by the independently confined worker lifecycle. Preserve commit/branch/evidence; do not merge or deploy. No further sandbox investigations in this task. |
| M5 — Security & reliability | **M5.1 + M5.2 COMPLETE** — login-startup and HTTP transport security deployed and physically accepted 2026-11-10; remaining auth/execution risks and M4.1 deferred |
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
human acceptance; it does not claim new automated or physical checks. Steering subsequently
accepted deployed M3.4 and M3 production closure. M4.1 passed isolated physical acceptance
but is deferred to M5. Configure subsequently deployed and passed physical production
acceptance, as confirmed by Steering on 2026-11-10. See ROADMAP's individual
slice records for historical evidence boundaries.


Current Steering status (2026-11-10): **M5.1 COMPLETE — production and physical
post-login acceptance PASS**. Native Aqua user LaunchAgent `local.phonedeck` starts
authorized release `4f75b99f760b73f846be6870161cbac3590fd417` after login;
authenticated HTTP/HTTPS/WSS, unchanged token/TLS/sandbox, no duplicate process and
working iPhone 11 were verified. The user intentionally saved a new seventh control
(Safari, id `key-1`, replacing Activity Monitor, id `app-7`) after login. Its
new V2 revision `e877d78bd16a5d15` is valid user state; the legacy projection
status `unrepresentable` does not evidence damage. Preserve current state and do not
restore the superseded `config.json.prev`. Full reboot not tested; login startup was.
M5 remaining security scope and M4.1 remain open. No further deployment or restart
is authorized by this documentary closure.

Current Steering acceptance update (2026-11-10): **M5.2 COMPLETE** on merged
`main` `577420fbdad00c3892cafc845502c40b74f9a229`; physical iPhone 11
HTTPS Home Screen acceptance PASS. Production cutover report confirmed LAN HTTP
control denials (IPv4/IPv6), HTTPS/WSS, local OBS/MJPEG protocol, release-aware
health, LaunchAgent continuity and preservation of latest V2 revision
`e877d78bd16a5d15` including Safari `key-1`, credentials/TLS and sandbox.
No app or Shortcut was executed during acceptance; actual OBS application output
and a fresh logout/reboot were not tested. M5.1 remains complete; M5 as a whole,
unscoped token risk and deferred M4.1 remain open. No new production operations
authorized by this closure.

## Open ChatGPT Shortcut — end-to-end acceptance (2026-11-10)

**Status: COMPLETE — production configuration and real iPhone 11 execution PASS.**
Reused the existing M3.3 approved-UUID Shortcut path; no product code, API, sandbox
policy, TLS or token change. The user created the native macOS Shortcut
`Open Chatgpt` (Safari Create New Tab → `https://chatgpt.com/`). Its actual UUID
`CE71C698-08EA-4D59-8C91-53790C9EDFF8` was verified against the native
Shortcuts catalogue. The existing private approval mechanism was validated,
installed with a single `Open ChatGPT` label/UUID authorization, and loaded
after a single controlled `gui/501/local.phonedeck` restart. HTTPS `/launcher`
catalogue, M5.2 HTTPS/WSS health, HTTP LAN denial, credentials, TLS and sandbox
were reported PASS; rollback assets remained ready.

The user then explicitly replaced the prior Safari `key-1` seventh control in
PhoneDeck Configure and saved the new seven-control V2 selection with Internet
and Batteries widgets retained. **The saved configuration intentionally differs
from the earlier M5.2 revision `e877d78bd16a5d15`; a new revision was not
supplied. Do not restore the superseded seventh control or stale backups.**
Steering authorized one real execution; the user confirmed one iPhone 11
Home Screen tap, PhoneDeck status `Completed`, and Safari on the Mac opening
`https://chatgpt.com/`. This constitutes real end-to-end acceptance of this
specific Shortcut integration. No further Shortcut executions or automatic
retries are authorized by this documentation closure.

M5.2 remains COMPLETE on production binary
`577420fbdad00c3892cafc845502c40b74f9a229`; the documentation-only
GitHub main SHA does not imply a newer deployed binary. The other six controls
and widgets were reported retained; their independent actions were not
re-executed as part of this test. M5's remaining authentication/reliability
risks and deferred M4.1 remain open.

## M5.3-S2 — TLS private material: final Steering acceptance (2026-11-11)

**STATUS: COMPLETE — merged, production remediation, controlled deployment and
physical iPhone 11 acceptance PASS.** M5.3-S1 identified one reproducible MEDIUM
local-reader risk (`server.key` and `server.p12` at `0644`) but no HIGH authentication
bypass or unauthorized execution. The existing full-control bearer model was
provisionally accepted for this slice, not replaced with scopes or OAuth.

The M5.3-S2 fix (ADR-021) landed via [PR #17](https://github.com/AdrianJTorres/OldPhoneDeck/pull/17)
at `8e46ce8eee719c623c6e0357652fd5ec1067008f`. It reserves
`ca.key`, `server.key` and `server.p12` at `0600` before writing and rejects
insecure retained identities without silent repair or regeneration. Focused
validation: 14 TLS/HTTPS/WSS and 5 managed-startup tests PASS; warning-free release;
one independent T3 review PASS with its specific CA-regeneration finding fixed and
rechecked. Those were implementation/review results, not new physical tests.

In a separately authorized permissions-only production operation, Codex reported
`server.key` and `server.p12` changed to `0600` (`ca.key` already `0600`),
identity bytes/CA fingerprint/IP mapping/token unchanged, private `0700` backup
verified, HTTPS/WSS and M5.2 HTTP restrictions PASS, and no process restart.
The subsequent controlled release cutover deployed the merged source with one
managed LaunchAgent restart; Codex reported active PID `88786` surviving the
deployment shell, health PASS, all TLS private files at `0600`, unchanged
certificates/token/sandbox/plist, a verified rollback backup and no rollback.

**Final physical acceptance (user-confirmed):** iPhone 11 Home Screen HTTPS
connected; all seven controls rendered with **Open ChatGPT in position 6** and
**TradingView in position 7**; Internet/Batteries visible; Configure/Cancel worked
without saving; portrait and landscape both PASS. Production V2 revision
`bf4da13b431a2bf8`, complete control order/IDs/parameters/metadata and the
approved Open ChatGPT UUID `CE71C698-08EA-4D59-8C91-53790C9EDFF8`
were reported preserved. This release acceptance did **not** execute real apps
or Shortcuts or verify new OBS rendering. Do not restore older V2 revisions
(`e877d78bd16a5d15` and `85092ef77d2d8462` are superseded).

**M5.3-S2 is closed, not all M5.** Remaining reliability/ingress timeouts,
other documented residual security risks and deferred M4.1 stay separately open.
No further production operation is authorized by this documentary closure.
