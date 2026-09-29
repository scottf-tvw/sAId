# sAId Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone macOS menu-bar app: hold Right-Option, speak, release → completed Moonshine text is pasted at the cursor; a floating HUD shows live Moonshine words while holding.

**Architecture:** One Swift 6 process. The pure `DictationReducer` drives a `DictationController` actor. One resident `MoonshineEngine` actor serves separate preview and final protocols. Audio is captured once, ordered and buffered; after release, streaming stops and the complete utterance is transcribed before postprocessing and insertion. UI observes controller snapshots on the main actor.

**Tech Stack:** macOS 15+, Apple Silicon, Swift 6 strict concurrency, SwiftUI/AppKit, AVFoundation/CoreAudio, CoreGraphics, moonshine-swift **exactly 0.1.5**, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-29-said-dictation-design.md` (amended by Scott: Moonshine for both roles).

This revision replaces the original sample implementations, which contained concurrency and behavior defects. Tasks 1–2 are already implemented and reviewed; inspect current sources and the implementation ledger before resuming. Do not recreate them. The engine-selection amendment removes Qwen/speech-swift/MLX. `docs/IMPLEMENTATION-NOTES.md` records the concrete rulings.

## Global Constraints

- One standalone process. No sidecar, Electron, IPC, LLM cleanup, idle unload, or memory-pressure machinery.
- One resident `.mediumStreaming` Moonshine model, language `en`. Its native calls are serialized. A preview-session failure must not block the final path while the model remains usable.
- Audio after conversion: 16 kHz mono Float32. Converter input returns `.noDataNow`, never `.endOfStream` when input is temporarily unavailable. Capture is not `@MainActor`; never transcribe in the audio tap.
- Swift 6 complete concurrency. No `@unchecked Sendable` declarations outside third-party engine adapters. Use checked actors/value types/Mutex ownership.
- `Bundle.main`, never `Bundle.module`. No app `print()`; `os.Logger` subsystem `org.tvw.said`. No transcript contents in logs.
- Never insert into secure input. Restore clipboard on every exit; preserve newer user clipboard changes. Partial preview text is never pasted.
- Right Option keycode 61, Esc cancels. Minimum 250 ms of captured audio; exact 120-second audio cap. No overlap; late session/timer callbacks cannot mutate another utterance.
- Keep MIT notices on Parakey-derived hotkey, insertion, correction, and filler code.
- Branch per task, PR to `main`; don't commit directly to main. Check current merge authorization before merging.
- Hardware/TCC checks belong to Scott (`docs/SMOKE.md`), reported as **needs smoke**. Never lock the Mac or acquire a Computer Use lock.
- Each behavior follows failing test → implementation → green → commit. No tautological tests, blanket sleeps, or real microphone use in unit tests. Model tests are explicit opt-in and offline.

## Layout and interfaces

- `Sources/sAId/App/`: SwiftUI entry, delegate, main-actor view model.
- `Core/`: existing `DictationState`, `DictationReducer`; later controller executes ordered effects.
- `Engines/`: existing protocols; `MoonshineEngine`, `ModelCache` and download support.
- `Audio/`: converter feeder/conversion ownership and capture lifecycle.
- `Text/`: corrections, filler removal, postprocessing.
- `Hotkey/`: pure decider and main-run-loop tap listener.
- `Insert/`: pasteboard snapshot, insertion transaction, Unicode strategy.
- `UI/`: HUD, menu, settings, history, permissions.
- `Support/`: existing logger; history, settings, permissions.
- `Tests/sAIdTests/`: unit and opt-in contract tests. `Tests/Fixtures/`: three synthetic speech WAVs and reference text.
- `Resources/`: default corrections/fillers, icon if an SF Symbol is insufficient.
- `project.yml`, `Info.plist`, `sAId.entitlements`, `Makefile`, `scripts/`: app build/install/release/benchmark.

Existing engine interfaces (Task 7 changes the preview return to AsyncThrowingStream so native asynchronous errors, including stop-time failures, can reach the controller):
```swift
struct PreviewLine: Sendable, Equatable { let text: String; let isFinal: Bool }
protocol FinalTranscriber: Sendable {
    func transcribe(_ pcm16k: [Float]) async throws -> String
}
protocol PreviewTranscriber: AnyObject, Sendable {
    func start() async throws -> AsyncStream<PreviewLine>
    func feed(_ pcm16k: [Float]) async throws
    func stop() async
}
```
The reducer's actual API is in `Sources/sAId/Core/`. It uses a `DictationState` struct containing readiness, phase, independent message, physical-held/queued intent, and session/timer IDs. Events/effects carry their IDs. Do not substitute the original enum-only sample. `finalText` receives postprocessed output and preserves its spacing; only a trimmed copy determines emptiness.

### Task 1: Reproducible baseline — complete, Moonshine amendment complete

**Files:** `Package.swift`, `Package.resolved`, `Sources/sAId/App/sAIdApp.swift`, `Tests/sAIdTests/SkeletonTests.swift`, `README.md`, `CLAUDE.md`, `NOTICE`.

- [x] Replace CLI placeholder with SwiftUI menu-bar entry and testable import.
- [x] Build and module-import smoke test; reviewed PR #1.
- [ ] Apply Scott's amendment: remove speech-swift/Qwen and all transitive dependencies, pin Moonshine exactly 0.1.5, update dependency documentation. Run `swift package resolve`, `swift package show-dependencies`, `swift build`, `swift test -Xswiftc -strict-concurrency=complete`; review and PR.

### Task 2: Pure reducer and actor-compatible protocols — complete

**Files:** existing `Core/DictationState.swift`, `Core/DictationReducer.swift`, `Engines/EngineProtocols.swift`, `Support/Log.swift`, `Tests/sAIdTests/DictationReducerTests.swift`.

- [x] Test readiness independently of messages, actual-audio threshold/cap, cancellation, queued press/release, final-vs-preview history, session/timer identity, and error recovery.
- [x] Preserve optional trailing space and retain outstanding finalization through readiness failure/recovery.
- [x] 41 reducer tests plus import test pass, strict concurrency build passes; review and scoped re-review clean. PR #2.

### Task 3: Corrections, fillers, protected tokens

**Files:** create `Sources/sAId/Text/Corrections.swift`, `FillerRemoval.swift`, `PostProcess.swift`, `Resources/default-corrections.json`, `default-fillers.json`; test `Tests/sAIdTests/PostProcessTests.swift`.

**Interfaces:** `Correction: Codable, Equatable, Sendable` with `from`/`to`; `CorrectionsStore(fileURL:)` with load/save and `defaultURL`; `PostProcess(corrections:fillers:trailingSpace:)` with `apply(_:) -> String`. Values passed across actors are checked Sendable. Surface malformed-file errors without overwriting users' data.

- [ ] Write tests first, including:
```swift
XCTAssertEqual(pp.apply("um hello tvw"), "Hello TVW")
XCTAssertEqual(pp.apply("it is, you know, fine"), "It is fine")
// With correction said→SAID and filler um:
XCTAssertEqual(pp.apply("see org.tvw.said and https://x.y/um"), "See org.tvw.said and https://x.y/um")
```
Also cover whole-word Unicode boundaries, multiword longest-first corrections, literal replacement `$`/backslashes, empty rules, protected numbers/URLs/code tokens through ALL stages, correction casing at the beginning (`mimoLive`), leading brand casing (`iPhone`), punctuation cleanup, optional trailing space, and JSON round trip/corruption.
- [ ] `swift test --filter PostProcessTests` must fail before implementation.
- [ ] Implement corrections → filler removal → first-letter casing → optional trailing space. Use protected spans or equivalent without sentinel collisions. Do not lowercase replacement strings. Empty results stay empty.
- [ ] Defaults: invintus→Invintus, tvw→TVW, mimo live→mimoLive, live bus→LAIveBus, ndi→NDI; fillers `um`, `uh`, `er`, `hmm`, `you know` (avoid globally deleting meaningful `like`). Keep source attribution.
- [ ] Run focused tests plus `swift build`; commit reviewed task.

### Task 4: Ordered audio capture and lifecycle recovery

**Files:** create `Sources/sAId/Audio/ConverterFeeder.swift`, `AudioCapture.swift` (split lifecycle/conversion if needed); test `Tests/sAIdTests/ConverterFeederTests.swift`, `AudioCaptureTests.swift`.

**Interfaces:** `CaptureSource: Sendable` with `start() async throws -> AsyncThrowingStream<[Float], Error>` and `stop() async`. Each start returns a fresh stream. Stop terminates production only after previously accepted chunks are yielded, finishes the stream, and is idempotent. The controller waits for its consumer to drain. `AudioCapture` conforms and accepts input-device UID configuration; empty UID means system default.

- [ ] First test `.haveData` exactly once for an enqueued synthetic buffer, then `.noDataNow`, including a second press cycle. Test real conversion 48 kHz mono/stereo → 16 kHz mono and ordered samples with finite values.
- [ ] Test capture lifecycle using a narrow backend seam for start failure, ordered queued chunks on stop, configuration change, wake, device loss, restart, and repeated stop. No mic or permission prompts.
- [ ] Run focused tests to observe failures.
- [ ] Implement non-main-actor ownership. AVFoundation buffers cannot outlive their callback without copying/ownership; no unsafe cross-thread mutable fields. Use checked actor/Mutex isolation and a nonisolated tap closure. Conversion is allowed in the tap if prompt; inference is not.
- [ ] Select CoreAudio device by UID; check setter errors. Rebuild on configuration/wake notifications; mid-session loss finishes with an error, next press can recover. Remove observers/tap safely at shutdown.
- [ ] Run focused tests and strict-concurrency build, document actual stream/drain interface, commit.

### Task 5: Physical hotkey handling

**Files:** create `Sources/sAId/Hotkey/HotkeyDecider.swift`, `HotkeyListener.swift`; test `Tests/sAIdTests/HotkeyDeciderTests.swift`. Read `docs/borrowed/parakey-hotkey-listener.swift`.

**Interfaces:** `HotkeyAction: Sendable, Equatable` cases `pressed`, `released`, `cancel`, `none`. Pure `HotkeyDecider` maps event type/keycode/flags/autorepeat into actions; listener is main-actor isolated, exposes start/stop and a synchronous main-actor action callback or ordered stream.

- [ ] Tests before implementation: right-vs-left Option, both Options held then right released, repeated ordinary keydown, Esc while held, Esc release, modifier cancellation followed by release, stop/reset, configurable ordinary and modifier keys.
- [ ] Verify failures with `swift test --filter HotkeyDeciderTests`.
- [ ] Port attributed listener/decider logic. Physical side is authoritative, since Option masks are side-agnostic. Use event snapshots at actor boundaries; avoid unowned raw pointers after teardown.
- [ ] Tap watches flagsChanged, keyDown/keyUp, re-enables on timeout, logs failures. Start/stop are idempotent. Never invoke real tap/input APIs in unit tests.
- [ ] Test/build and commit; hardware/TCC needs smoke.

### Task 6: Safe insertion transaction and selectable Unicode fallback

**Files:** create `Sources/sAId/Insert/PasteboardSnapshot.swift`, `TextInserter.swift`, optional strategy helper; test `Tests/sAIdTests/TextInserterTests.swift`. Read attributed Parakey insertion reference without inheriting its clipboard policy.

**Interfaces:** `TextSink: Sendable { func insert(_ text: String) async throws }`; main-actor `TextInserter` conforms. Errors distinguish secure input, unavailable permission/event creation, and failed setup. Accept injectable pasteboard/event/secure-check/delay seams for safe tests. Insertion strategy is clipboard paste or direct Unicode.

- [ ] Test snapshot/restore for multiple items/types, empty clipboard, failed snapshot, failed write/event creation, cancellation during restore delay, a newer external clipboard change, concurrent insertion requests, and secure-input refusal (zero clipboard/events).
- [ ] Test Unicode chunking including composed emoji/surrogates; known pre-delivery setup failure may fall back, unknown delivery acceptance must not duplicate text.
- [ ] Observe failing tests, implement exclusive transaction ownership. Secure-check immediately before posting; restore in guaranteed cleanup even on cancellation, but do not overwrite a newer external change. Approximately 150 ms normal paste restore delay.
- [ ] Never interpret CGEvent construction as target-app acknowledgment. On failure keep text available to History; preserve clipboard. UI copy must say `Paste failed — copy from History`.
- [ ] Run focused tests/build; commit. No real general-pasteboard mutation or synthesized desktop events in tests.

### Task 7: Shared resident Moonshine engine, download/cache, live preview

**Files:** modify `Sources/sAId/Engines/EngineProtocols.swift`; create `Sources/sAId/Engines/MoonshineEngine.swift`, `ModelCache.swift` and small download/checksum helpers as needed; tests `Tests/sAIdTests/MoonshinePreviewEngineTests.swift`, `ModelCacheTests.swift`; copy synthetic WAVs/reference JSON/provenance into `Tests/Fixtures/`.

**Interfaces:** amend `PreviewTranscriber.start()` to return `AsyncThrowingStream<PreviewLine, Error>` and keep `stop() async`; a native stop-time error finishes that session stream with an error, retaining the model for final transcription. `actor MoonshineEngine: PreviewTranscriber` with `init(modelRoot: URL = defaultModelRoot)`, `load(progress: (@Sendable (Double, String) -> Void)?) async throws`, and keyterm configuration. Task 8 adds `FinalTranscriber` to the SAME actor/model. `PreviewLine.text` is aggregated whole-utterance text, not only the latest native line.

- [ ] Unit tests first for cache completeness/corruption, atomic downloads, primary failure → official mirror, checksum failure, progress clamping, cancellation, and keyterm sanitization. Use injected local HTTP/data transport; no unit-test network.
- [ ] TDD preview adapter lifecycle via a narrow native-runtime seam: fresh stream per start, stop/close once, two sequential utterances, ordered line updates replacing matching IDs, partial→completed text, start/feed failure, later recovery, no model unload on stop.
- [ ] Implement one actor owning native `Transcriber` and at most one current `Stream`. Serialize native calls, never run on main actor, finish per-session AsyncStreams. Inspect upstream deinit/close to avoid double frees. Feed errors propagate; native TranscriptError callbacks are surfaced without silently dropping failures.
- [ ] Cache root `~/Library/Application Support/sAId/models/moonshine/`; use native catalog `.stt(language:"en", modelArch:.mediumStreaming)`. Native C dependency API is available if needed for manifest access; don't duplicate a guessed filename list. Validate safe paths, sizes and available catalog checksums. CDN failure falls back to equivalent `https://huggingface.co/moonshine-ai/moonshine-voice-assets/resolve/main/` asset paths. Complete cache requires no network.
- [ ] The implementation-session CDN returned 403; exact files were downloaded from the official mirror and SHA-verified in the default cache. The model is ready for offline contract tests. Do not delete or overwrite unrelated caches.
- [ ] Add opt-in `SAID_MODEL_TESTS=1` tests with three real WAV fixtures; absent/incomplete model skips without downloading. Assert meaningful nonempty transcript and conservative WER ceiling, then another session to detect dead-stream regressions. Test helpers locate fixtures using source-relative paths, not Bundle.module.
- [ ] Run unit suite and offline model tests; record actual transcripts/latency and any platform limits; commit.

### Task 8: Moonshine final transcription on the same model

**Files:** modify `Sources/sAId/Engines/MoonshineEngine.swift`; create `Tests/sAIdTests/MoonshineFinalEngineTests.swift`.

**Interfaces:** add `FinalTranscriber` conformance with `transcribe(_ pcm16k:[Float]) async throws -> String`. Call resident `Transcriber.transcribeWithoutStreaming(audioData:sampleRate:flags:)`, rate 16000; concatenate ordered transcript lines. No second model load, Qwen dependency, or preview substitution.

- [ ] Write failing tests for not-loaded error, empty/silent input, final after preview stop, no concurrent native streaming/final calls, cancellation boundaries, native failure, and reuse after failure. Keep implementation test seams narrow.
- [ ] Implement final method on the shared actor. Reject invalid nonfinite audio, serialize ownership, and ensure cancellation prevents late results reaching insertion. Third-party synchronous inference may only observe cancellation at boundaries; document that honestly.
- [ ] Run `SAID_MODEL_TESTS=1 swift test --filter MoonshineFinalEngineTests` against all three offline WAVs, assert nonempty/word-error ceiling and compare resulting ordered text. Measure output and elapsed time, not a silence-only tautology.
- [ ] Test/build and commit. Model quality on Scott's voice remains for his corpus.

### Task 9: Ordered controller and HUD

**Files:** create `Sources/sAId/Core/DictationController.swift`, `UI/HUDPanel.swift`, `UI/HUDView.swift`; tests `Tests/sAIdTests/DictationControllerTests.swift`, `HUDViewModelTests.swift`, actor-safe fakes.

**Interfaces:** controller actor owns one existing `DictationState` for its lifetime; consumes actual reducer effects, CaptureSource, preview/final protocols (same engine object), TextSink, Sendable PostProcess and history callback carrying text/target identity. Expose currentState, state snapshots, ordered hotkey entry, model readiness, configure/enable, and shutdown. Main-actor HUD observes state.phase plus independent state.message.

- [ ] Tests before code using deterministic barriers: ordered final-chunk drain on release; cap trims to exactly 1,920,000 samples; short taps use audio duration; capture startup/midstream failure; preview failure preserves final; repeated sessions; stale completions/timers; queued held press starts only after insertion/clipboard restore; release/cancel withdraws queue; final-vs-preview history source; empty postprocessed output; disable/shutdown; readiness failure/recovery.
- [ ] Run failing controller tests. Never use unchecked fake mutable state or fixed sleeps as synchronization.
- [ ] Execute effects in order, retaining task handles and session IDs. Release stops audio production and drains buffered accepted chunks before sending release/final work. Avoid deadlock if cap triggers from inside the audio-consumer task. Preview work must not delay audio acceptance or lose final audio. Late callbacks cannot reuse a newer session's target app identity.
- [ ] Postprocess final text once before `.finalText`. Record only through the reducer's history effects, avoiding duplicate success entries. Propagate insertion/capture failures with truthful UI messages.
- [ ] HUD: nonactivating floating NSPanel, no focus/mouse capture; bottom-center of screen under pointer; trailing ~12 words, listening pulse, finalizing spinner, completed/error/nothing-heard/loading states, 600 ms shown and 2 s errors. Ignore a stale hide timer. Unit-test presentation mapping without opening a window.
- [ ] Build/test and commit; actual HUD behavior needs Scott's smoke test.

### Task 10: Full app shell and signed .app

**Files:** `App/sAIdApp.swift`, `AppDelegate.swift`, `AppViewModel.swift`; `UI/MenuView.swift`, `SettingsView.swift`, `HistoryView.swift`, `PermissionsView.swift`; `Support/History.swift`, `Permissions.swift`, settings/model-status support; `project.yml`, `Info.plist`, `sAId.entitlements`, default resources; corresponding unit tests.

- [ ] TDD pure stores and permission/readiness decisions: last 50 history entries with date/target/source/failure; corruption surfaces without data loss; clear stays clear in all windows; persistence; all three grants required; model/permission retry gating; settings validation and updates.
- [ ] Wire one shared engine, controller, history store and settings model. Show initial loading immediately. Retry model errors. Stream failure can degrade preview; model failure disables dictation. Enable toggle must gate actual hotkey actions and stop active capture on disable.
- [ ] Menu: Dictation on/off, Copy last transcript, History, Settings, Copy diagnostics, Quit. Diagnostics omit transcript contents/secrets.
- [ ] Settings: supported hotkey picker, microphone picker with system default, true correction add/edit/delete/import/export, filler enable/custom additions, trailing space, insertion strategy, model progress/status/cache location/retry/reset. Changes apply coherently, with explicit UI if any setting needs relaunch. Reset confirmation affects only app model cache while idle; shared model state must not race inference.
- [ ] Shared History window supports copy and clear and reflects new entries while open. Corrections empty list stays intentionally empty rather than reloading defaults.
- [ ] First-run permission checklist (Microphone, Input Monitoring, Accessibility), direct System Settings links, grant/recheck polling while window is visible; stop polling after success/close. Reopen when grants disappear. Do not request permissions from automated tests.
- [ ] Xcodegen: application `org.tvw.said`, macOS15, Swift6 complete, LSUIElement, microphone purpose text, hardened runtime/audio-input entitlement, pinned Moonshine package. Copy JSON where Bundle.main actually finds it. Native arm64 app. Developer ID team M2TEAF948X is available; verify identity before signing. No placeholders in generated config.
- [ ] `xcodegen generate`; `xcodebuild -project sAId.xcodeproj -scheme sAId -configuration Debug -destination 'platform=macOS' -derivedDataPath build build` with pipeline failure preserved; `swift test`. Verify codesign/entitlements and resources. Don't launch or manipulate desktop automatically.
- [ ] Commit and PR; needs smoke.

### Task 11: Benchmark, install/release, final review and handoff

**Files:** `scripts/bench.sh`, `scripts/release.sh`, `Makefile`, `Sources/said-bench/` or equivalent shared-library CLI, package layout if needed, script tests, `README.md`, `docs/HANDOFF.md`, `docs/SMOKE.md`.

- [ ] Add benchmark CLI using the SAME Moonshine implementation, not duplicate inference logic. A small shared engine library target is acceptable; avoid making the entire UI public. Read 16k mono PCM16 WAV/ref pairs; print normalized WER, elapsed time, per-file and corpus aggregate edit/reference counts. Document empty-reference treatment and return failures on invalid audio/model errors.
- [ ] Test WER known cases and shell failure propagation with stub tools; no repeated network/model loading per file. Provide fixture command and Scott's optional 20-sentence jargon corpus instructions.
- [ ] `make build`, `make test`, `make app`, `make install` must preserve failures. Install builds before replacing /Applications/sAId.app; preserve previous app until new copy verified. Leave launch explicit for Scott while he uses Splashtop.
- [ ] Release script sets requested version, creates dist, signs with verified Developer ID/hardened runtime, checks signature, notarizes using `said-notary` keychain profile, staples, produces zip. Never print credentials; fail clearly if profile unavailable. Don't publish a GitHub release without authorization.
- [ ] Run full unit suite, offline engine fixture tests, benchmark, signed Debug/Release builds and signature/resource checks. Independent final whole-branch review; fix load-bearing findings with focused regressions.
- [ ] Update truthful handoff/README with current branch/PRs, build commands, model paths, measured verification, unresolved hardware checks and any exact assistance needed. Account for every spawned process; stop finished duplicate pingers/idle waiters, leave real active work alone.
- [ ] Ask Scott for hardware/TCC smoke only after a concrete app is ready. First milestone: in Notes, hold Right Option → live words → release → final text appears → original clipboard returns. Do not mark manual rows passed without his report.
