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

**STATUS: IN PROGRESS**

Understand the repository completely before modifying it, then record the result.

- **M1.1 — Repository analysis:** COMPLETE and accepted by Steering. Full architecture
  map, request flow, endpoint inventory, macOS integration list, persistence map,
  frontend analysis, extension points, risks (HIGH / MEDIUM / LOW).
- **M1.2 — Project documentation:** this branch (`docs/project-steering`). Establishes
  `AGENTS.md`, `docs/STEERING.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`,
  `docs/DECISIONS.md`. No product code changes.

Exit criteria: documentation accepted by Steering; no `Sources/**` or `Package.swift`
change; project still builds.

## M2 — Foundations

**STATUS: NEXT**

Implement only the minimum architectural foundations required for safe extensibility.
Foundational boundaries — features must not be built ahead of them.

- **Action model / registry** — an internal representation of an approved action, with a
  server-side allowlist. No arbitrary shell execution, ever.
- **Versioned configuration** — a configuration format that can express controls, action
  types and metadata, with explicit migration that preserves the existing launcher
  selection.
- **Minimum ingress hardening** — request/header/connection limits enforced *before* body
  buffering; keep the auth boundary between "deck control" and high-consequence actions.

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
- **Auth** — resolve or explicitly accept the single-unscoped-token risk.
- **Ingress** — limits, timeouts, connection caps; close the pre-auth buffering gap.
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