# HANDOFF — sAId (updated 2026-09-29)

Read `CLAUDE.md`, the amended design, then the implementation plan. Scott authorized completing the project autonomously and asking for human help only when needed.

## Current decision

**Moonshine English Medium Streaming for BOTH live preview and final transcription.** Scott changed the original Qwen choice during this implementation session and supplied the official current-model list:
https://moonshine-voice.readthedocs.io/en/latest/models/available-models/#current-models

Use Swift `.mediumStreaming`, language `en`, one resident actor-owned native model, serialized streaming/final access. Qwen/speech-swift/MLX have been removed. Do not reintroduce them from historical commits. Final output is completed after release, postprocessed, then inserted; live partials remain display-only. No unmeasured accuracy superiority is claimed.

## Workspaces and integration

- Public MIT repo: `github.com/scottf-tvw/sAId`.
- Original checkout `/Volumes/Work/GitDev/sAId` remains on `main`.
- **Active worktree:** `/Users/scottfreeman/.codex/worktrees/said-implementation/sAId`.
- Current branch: `task/3-postprocessing`, layered on reviewed Tasks 1–2 and the Moonshine amendment.
- [PR #1](https://github.com/scottf-tvw/sAId/pull/1): baseline menu-bar entry/test target (original engine pin, superseded by the amendment).
- [PR #2](https://github.com/scottf-tvw/sAId/pull/2): pure state machine and async engine protocols.
- [PR #3](https://github.com/scottf-tvw/sAId/pull/3): Moonshine-only dependency/design amendment (review clean).
- Task 3 (postprocessing) is complete and reviewed, commits `5205424`, `5b1c41a`; parent independently verified 52 strict-concurrency tests. Wrapped URL, filler punctuation, and normalized correction priority regressions are fixed.
- Merge authorization was requested and remains pending. Continue implementing task branches; don't infer merge approval from the engine-choice discussion.
- Recovery ledger: `.superpowers/sdd/2026-09-29-said-implementation/progress.md` in the active worktree. It contains task commits, reviews, fixes, and preflight rulings. Scratch reports/briefs/logs are ignored and must NOT be force-added to git.
- Durable design corrections: `docs/IMPLEMENTATION-NOTES.md`.

## Completed and verified

1. Task 1: SwiftUI menu-bar placeholder replaces CLI main; module-import smoke test. Baseline review clean.
2. Task 2: checked-Sendable state/reducer/protocols/logging. **41 reducer tests + 1 import test pass** with Swift 6 complete concurrency. Review found and fixed trailing-space loss and readiness recovery reopening capture during outstanding inference; scoped re-review clean. Core implementation commits `1706ef8`, `db96ed5`.
3. Engine amendment: Package.swift now pins **moonshine-swift exactly 0.1.5**; Package.resolved contains that dependency only. Build/test passed with 42 tests. Amendment review passed; PR #3 is open.

4. Task 3: deterministic corrections, fillers, protected tokens, casing and optional trailing space; atomic corrections JSON persistence. Intentional empty rules stay empty; corruption is surfaced without overwriting data. Review clean after one fix round. **52 tests pass** with strict concurrency.

The actual application UI/capture/insertion/engine adapters are still to be implemented. A compiled menu-bar placeholder is not an end-to-end app.

## Current interfaces

`DictationState` is a struct with independent model readiness, phase, HUD message, physical-held/queued intent, monotonic session IDs and timer IDs. See current `Core/` sources; the original enum-only plan sample was defective and has been replaced.

- `PreviewTranscriber.start() async throws -> AsyncStream<PreviewLine>` returns a fresh stream per utterance.
- `feed(_:) async throws`, `stop() async`.
- `FinalTranscriber.transcribe(_ pcm16k: [Float]) async throws -> String`.
- Preview lines contain aggregated whole-utterance text.
- `finalText` receives already-postprocessed final text, preserving trailing space. Blank detection uses a trimmed copy.
- Effects/events carry session/timer identity. Controller must preserve IDs, drain ordered audio before finalizing, trim cap samples exactly, and display independent HUD messages.
- Queued presses start after insertion completion only while still held; release/cancel withdraws them. The model-readiness state is not proof that in-flight inference has finished.

## Models and test fixtures

- Eight Moonshine files are cached at `~/Library/Application Support/sAId/models/moonshine/`.
- Catalog variant: `model/medium-streaming-en/quantized_26_08_21` from Moonshine 0.1.5's native catalog.
- Primary CDN returned HTTP403. The exact files were downloaded from the official `moonshine-ai/moonshine-voice-assets` Hugging Face mirror; sizes and published SHA256 hashes were verified. Downloader must handle that fallback for users too.
- All download processes have finished. The unused Qwen files downloaded during this run were removed; no pre-existing model cache was deleted.
- Three synthetic WAVs and reference/provenance files are in the ignored ledger workspace's `fixtures/` directory, ready for Task7 to copy into `Tests/Fixtures/`. Generated by macOS Samantha, 155 words/minute; 16 kHz mono PCM16, around 2.4 seconds each. They test the pipeline, not Scott's voice accuracy.
- A scratch native API probe loaded one Medium Streaming model and transcribed all three fixtures sequentially. Two matched reference wording; the first normalized nine to 9 a.m. This verifies native full-utterance support, not the unimplemented app adapter. Ordinary tests must remain offline and avoid model downloads. Explicit `SAID_MODEL_TESTS=1` enables cached-model contract tests.

## Build and runtime facts

- Swift 6.3.3 / Xcode 26.6; current baseline builds without warnings.
- Each worktree needs its own `.build`. Symlinking the original cache produced duplicate absolute module paths and compiler crashes; a clean independent build passed.
- xcodegen is installed. Developer ID identity exists for **Scott DL Freeman, team M2TEAF948X**; verify it when configuring packaging.
- SPM alone does not produce the final .app bundle/TCC identity. Task10 creates the Xcodegen project and signed app.
- Resources use Bundle.main. No app print(), no unchecked Sendable outside native engine adapters, no transcription in tap, converter input never reports endOfStream for temporary absence.
- Borrowed Parakey code requires its MIT notice. Its old clipboard policy is not ours: preserve/restore clipboard with newer-user-change protection.

## Next work

Continue Tasks 4–11 in order; Task 4 audio capture is next. The Moonshine amendment is complete and remaining task briefs have been regenerated. The old sample code has been replaced by corrected contracts and test requirements; follow the amended spec and actual implemented interfaces.

Human assistance is expected once a signed full app is ready: grant Microphone/Input Monitoring/Accessibility and run `docs/SMOKE.md` in Notes and the other target apps. Real paste delivery, clipboard restoration, secure-input refusal, device changes, sleep/wake, and memory soak are **needs smoke**. Nothing has been marked passed without Scott's verification.

Scott uses the Mac through Splashtop. **Never lock the screen or invoke a Computer Use lock workflow.** No microphone capture, permission grants, synthetic desktop events, or screen automation have been performed in this implementation run.
