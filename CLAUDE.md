# CLAUDE.md — sAId agent manual

sAId is Scott's **standalone push-to-talk dictation app for Apple Silicon**: hold Right-Option,
speak, release → accurate text is pasted at the cursor; a floating HUD shows live words while you
hold. Two on-device engines: **Qwen3-ASR 1.7B** (final text) and **Moonshine mediumStreaming**
(live preview). No sidecar, no Electron, no IPC — that is the whole reason this app exists.

## Required reading, in order
1. `docs/superpowers/specs/2026-09-29-said-dictation-design.md` — the approved design. §0 is the
   decision table; §2.2 the state machine; §2.3 the audio invariants. Do not re-open decided items.
2. `docs/HANDOFF.md` — where things stand right now, what's verified, what's next.
3. `docs/superpowers/plans/` — the implementation plan; execute tasks in order.
4. `docs/borrowed/README.md` — the Parakey reference code and its attribution rule.

## Build & test
```bash
swift build                 # SPM: engines link; fast compile checks
swift test                  # unit tests (no models needed)
xcodegen generate           # once project.yml exists (plan task) → sAId.xcodeproj
xcodebuild -project sAId.xcodeproj -scheme sAId -configuration Debug build   # the .app bundle
```
SPM builds a CLI binary; the menu-bar app, HUD and TCC identity need the `.app` from xcodegen.
First `swift build` compiles MLX Metal shaders — expect several minutes; later builds are quick.

## Non-negotiables
- **Standalone.** No control channel, no parent process, no idle-unload/memory-pressure machinery
  in v1. Both engines stay resident.
- **Audio invariants (spec §2.3)** are law: converter block returns `.noDataNow` never `.endOfStream`;
  `AudioCapture` is not `@MainActor`; never transcribe inside the tap; `Bundle.main` not `Bundle.module`.
- **Never paste into secure input** (`IsSecureEventInputEnabled()`); always restore the clipboard.
- **Preview text is never pasted.** Only the final engine's output reaches the Inserter.
- **Attribution.** Any file that ports Parakey code keeps the MIT notice line from
  `docs/borrowed/*.swift`. Ported regions: hotkey listener, text insertion, corrections/filler helpers.
- **No credentials in the repo.** Models download from public sources; no tokens.
- Swift 6 strict concurrency stays on. No `print()` in app code — `os.Logger`, subsystem `org.tvw.said`.

## Method
- Strict TDD: failing test → minimal code → green → commit. The state machine and PostProcess are
  pure and must be fully unit-tested with fake engines before any hardware work.
- Branch per task; PR into `main`; never commit directly to `main` once the skeleton is in.
- Hardware/TCC steps (permissions, real mic, paste into real apps) are Scott's to verify — say so in
  the PR rather than claiming them done. `docs/SMOKE.md` is the checklist.
- Dev builds signed ad-hoc reset TCC grants. Fix stale entries with
  `tccutil reset ListenEvent org.tvw.said` (and `Accessibility`, `Microphone`) then relaunch.
  Sign with Developer ID (`scripts/release.sh`) for grants that persist.
- Keep this file and `docs/HANDOFF.md` truthful; update HANDOFF at the end of every session.

## Where things live
```
Sources/sAId/   App · Hotkey · AudioCapture · Engines (Qwen3FinalEngine, MoonshinePreviewEngine) ·
                PostProcess · Inserter · HUD · Permissions · Settings · History · Log
Tests/sAIdTests/
docs/borrowed/  Parakey reference regions (MIT) — reference only, not compiled
scripts/        bench.sh (WER on Scott's jargon set), release.sh (sign + notarize)
```
