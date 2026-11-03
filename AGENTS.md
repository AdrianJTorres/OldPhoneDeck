# AGENTS.md — operational contract for coding agents

This file is the entry point for any coding agent (Qwen Code, Codex, or anything else)
working in this repository. Read it before touching code. It states what the project
is, how to build and verify it, what must not change, and who is allowed to write.

Scope authority lives in `docs/STEERING.md`. Architectural facts live in
`docs/ARCHITECTURE.md`. Durable decisions live in `docs/DECISIONS.md`. Milestones and
their status live in `docs/ROADMAP.md`. This file does not override those; it tells
agents how to behave while working inside them.

---

## 1. What this project is

PhoneDeck is a personal evolution of **OldPhoneDeck** (upstream `GLAUCOMA82/OldPhoneDeck`,
MIT licensed): a small Swift executable that runs on a Mac and serves a browser-based
control surface to an old iPhone over the local network. The phone becomes a Stream
Deck — launch apps, drive Spotify / Apple Music, dictate a note into Claude, and read
network and battery status.

**PhoneDeck is not a rewrite.** OldPhoneDeck is the architectural base and is evolved
incrementally. Where the existing code already does something adequately, reuse it.

| Item | Value |
|---|---|
| Fork (`origin`) | `AdrianJTorres/OldPhoneDeck` |
| Upstream | `GLAUCOMA82/OldPhoneDeck` (reference only — never push to it) |
| Local clone | `/Users/adriantorres/Projects/PhoneDeck/OldPhoneDeck` |
| Baseline commit | `e6221841973a5cc2b21d4c8bbcdf6020eaca2f42` |
| Platform | macOS 14+, Swift 6.2 toolchain, SwiftPM |

Repo-local `gh` default repository is set to the **fork**, so `gh issue` / `gh pr`
target `AdrianJTorres/OldPhoneDeck`. Do not reset it to upstream.

---

## 2. Source layout

| Path | Contents |
|---|---|
| `Package.swift` | Single executable target `oldphonedeck`, `resources: [.copy("web")]`, links AppKit |
| `Sources/oldphonedeck/main.swift` | Entry point, options, token, LAN address, **the route table**, listener startup |
| `Sources/oldphonedeck/HTTPServer.swift` | Minimal HTTP/1.1 transport over `Network`, MJPEG streaming |
| `Sources/oldphonedeck/TLS.swift` | Private CA + server identity via `/usr/bin/openssl` |
| `Sources/oldphonedeck/PhoneMedia.swift` | Camera/mic WebSocket ingest, `AVAudioEngine` playback |
| `Sources/oldphonedeck/Control.swift` | macOS actions: app listing/launch, icons, Claude deep link, synthetic keys, launcher config |
| `Sources/oldphonedeck/Music.swift` | Spotify / Apple Music via AppleScript |
| `Sources/oldphonedeck/Stats.swift` | Network, speed test, batteries |
| `Sources/oldphonedeck/web/index.html` | The entire UI: inline CSS + ES5 JavaScript, one file |
| `docs/` | Steering, architecture, roadmap, decisions, screenshots |

---

## 3. Build, run, verify

```bash
swift build -c release          # ~105 s clean, faster incrementally
./.build/release/oldphonedeck   # run from the repo root (Bundle.module resolves web/)
```

- The binary serves HTTP on `8045`, HTTPS on `8047`, secure WebSocket on `8048`.
- **Do not** treat a missing full Xcode as a blocker. This Mac has only the Command
  Line Tools, so `xcodebuild` fails by design; the project is SwiftPM-only.
- **Do not** add a dependency to make a build or test easier. SwiftPM + stdlib +
  system frameworks is the whole stack.

### Verification expectations

1. `swift build -c release` must succeed. The baseline builds with **zero warnings**;
   do not leave new warnings behind.
2. There is currently **no test suite and no CI**. Until that changes, verify behaviour
   by running the binary and exercising the affected endpoints (`curl` with the token
   from `~/.oldphonedeck/token`), then state exactly what you ran and what you saw.
3. Never claim a check passed that you did not run. If a step needs a physical iPhone
   or a macOS permission dialog, say so and stop there.

---

## 4. Architecture constraints (hard)

These are not preferences. Changing one requires a Steering decision recorded as an ADR.

- **Swift + SwiftPM**, one executable target. No Swift packages beyond the standard
  library and system frameworks.
- **Zero / minimal dependencies.** No package manager additions, no vendored blobs.
- **Browser client stays a single hand-written file.** `web/index.html` is inline CSS
  and one ES5 IIFE. It must keep working on an iPhone 4S (iOS 8/9 Safari): no arrow
  functions, `let`/`const`, template literals, `Promise`, `fetch`, `Intl`, flex `gap`,
  and no build step.
- **LAN-first.** The Mac is the server; the phone is the client. No cloud service, no
  accounts, no telemetry leaving the machine.
- **Simple deploy model.** Build one binary, run it. No daemon manager, no container,
  no provisioning step beyond the documented permissions.
- **Do not introduce** Electron, React, Node, a database, or a web framework. If a task
  seems to require one, the task is wrong — raise it with Steering.

---

## 5. Security boundaries

The current security posture is documented in `docs/ARCHITECTURE.md` §9–§10. Agents
must not weaken it, and must not "helpfully" fix it outside the milestone that owns
the work.

Rules that always apply to **product code**:

- **Never expose arbitrary shell execution to the phone.** No endpoint may accept a
  command, a binary path, or a script and run it. Not even behind the token, not even
  "temporarily".
- **Every action is allowlisted.** The server decides what can be executed; the client
  only identifies which approved action to invoke. `Apps.isKnown` (`Control.swift`) is
  the reference pattern: validate against a server-side list, never trust the client's
  string.
- **Validate inputs against server-side state**, not against client-supplied metadata.
- **Keep the token out of logs, diagnostics and error messages.**
- Existing known risks (pre-auth body buffering, cleartext token channel, single
  unscoped token, `0644` TLS key material) are **recorded, not fixed** until M5.
  Do not fix them opportunistically; do not regress them either.

---

## 6. Allowed execution practices

- **Agents run the terminal.** Do not ask the human user to execute routine commands —
  builds, greps, `git` operations, `curl` checks, test runs. Perform them yourself and
  report the output.
- **Human intervention is reserved for** what an agent genuinely cannot do: macOS
  permission dialogs (Accessibility, Automation, Local Network), credential and
  authentication steps (GitHub login, tokens), physical-device checks on the iPhone,
  and scope/architecture decisions.
- **Read before you edit.** Read the surrounding code, its imports and its callers.
  Match existing naming, formatting and error style.
- **Stay inside the milestone.** Out-of-scope findings get recorded (in the report or
  in `docs/`), not fixed. This project has a documented anti-pattern: the drive-by fix.
- **No silent redesign.** If a change alters a boundary, a port, a config format, a
  data flow or a security control, it needs an ADR and an explicit Steering decision.
- **Do not commit build output.** `.build/` is excluded locally via `.git/info/exclude`
  because upstream ships no `.gitignore`. Keep the working tree clean.
- **No reformatting or renaming** as part of an unrelated change.

---

## 7. WRITE_OWNER rule

- **Exactly one WRITE_OWNER per branch or worktree.** The owner is named in the task
  brief and is the only agent that may modify files there.
- Every other agent on that branch is **read-only**: analysis, review, findings. They
  may read, build and run non-destructive commands; they may not edit, stage, commit or
  create files.
- If you are read-only and the task seems to require an edit, stop and report instead of
  writing.
- Do not run two writing agents against the same working tree. Use a separate worktree
  if parallel work is genuinely needed.
- Do not push to `upstream`, do not merge to `main`, and do not rewrite history unless
  the task explicitly says so.

---

## 8. Agent roles

### Qwen Code — T1 / T2 implementation

- Primary implementation agent for routine and moderately complex work.
- Repository analysis and documentation.
- Routine terminal work: build, run, inspect, `git` operations within the brief.
- Scoped implementation inside an approved milestone.
- Test and verification runs, including stating honestly what was and was not verified.

### Codex — T3, security-sensitive and independent review

- High-difficulty work: T3 tasks.
- Security-sensitive implementation (authentication, ingress limits, action
  authorization, TLS, anything that executes on the Mac).
- Difficult debugging where the cause is not visible from reading the code.
- Architecture-sensitive changes that alter a boundary.
- **Independent review** of another agent's work — a reviewer must not be the author.

### Steering — architecture and scope authority

- Owns the charter (`docs/STEERING.md`) and the roadmap.
- Decides which milestones exist, their order, and their scope.
- Accepts or rejects proposed architectural changes; ratifies ADRs.
- Resolves conflicts between "what is convenient" and "what the charter allows".
- Steering is a role, held by the human project owner.

### Routing summary

| Work | Agent |
|---|---|
| T1/T2 implementation, analysis, docs, routine terminal | Qwen Code |
| T3, security-sensitive, hard debugging, architecture-sensitive, independent review | Codex |
| Scope, milestones, architecture acceptance | Steering |

---

## 9. Documentation duty

Architecture and decisions are only useful if they are current.

- Update `docs/ARCHITECTURE.md` when a boundary, port, endpoint, data flow, file
  responsibility or persistence path changes.
- Add an ADR to `docs/DECISIONS.md` for every durable decision — especially ones that
  reject an obvious alternative. Record superseded ADRs; do not delete them.
- Update `docs/ROADMAP.md` status when a milestone starts or completes.
- Update this file if the build, verification or role contract changes.

Keep documentation honest about the difference between **current behavior** and
**planned architecture**. Never describe a planned feature as implemented.