# HANDOFF — sAId (updated 2026-09-29)

For the agent taking over. Read `CLAUDE.md` first, then the spec, then the plan.

## Where things stand
- **Repo**: `github.com/scottf-tvw/sAId` (public, MIT), original checkout `/Volumes/Work/GitDev/sAId`, branch `main`.
- **Active implementation worktree**: `/Users/scottfreeman/.codex/worktrees/said-implementation/sAId`.
  Scott authorized completing the project autonomously. Task 1 is built, tested, reviewed, and in
  [PR #1](https://github.com/scottf-tvw/sAId/pull/1). Task 2 (state machine) is complete on
  `task/2-dictation-state`, with 42 passing tests and a clean scoped re-review; do not restart
  Tasks 1–2. Shared-branch merge approval was requested and
  is pending. Work continues on task branches meanwhile.
- **Recovery state**: the worktree's ignored `.superpowers/sdd/2026-09-29-said-implementation/progress.md`
  tracks task commits, reviews, and plan corrections. [IMPLEMENTATION-NOTES.md](IMPLEMENTATION-NOTES.md)
  records durable decisions. The specification overrides defective plan sample code.
- **Latest user steering**: Scott changed the engine selection to Moonshine for both live preview
  and final transcription. Qwen will be removed. Updating the spec, plan, and dependencies is next;
  older Qwen references below are historical until that amendment lands. Generic engine protocols
  and reducer remain valid. No accuracy superiority has been asserted without measurement.
- **Design approved** through §1 by Scott on 2026-09-29; §2–§10 follow the same session's decisions.
  `docs/superpowers/specs/2026-09-29-said-dictation-design.md`. Decision table in §0 — do not reopen.
- **Skeleton builds**: `swift build` → "Build complete! (40.49s)" on Swift 6.3.3 / Xcode 26.6 /
  macOS 27.0 (M4 Max 36 GB), 2026-09-29. Both engine packages resolve and link:
  - `speech-swift` @ `main` (`1e6e0e5`), product `Qwen3ASR` — plus its `SpeechCore.xcframework` v0.0.14
  - `moonshine-swift` **0.1.5**, product `MoonshineVoice` — plus `Moonshine.xcframework` v0.1.5
  - transitive: mlx-swift 0.31.6, mlx-swift-lm 3.31.4, hummingbird, swift-nio…
  `Package.resolved` is committed. Task 1 pins `speech-swift` to that commit using `revision:`.
- Task 1 replaces `main.swift` with a SwiftUI menu-bar placeholder in `App/sAIdApp.swift` and an
  importable test target. The full application is still under implementation; hardware checks
  have not been run.
- A clean independent worktree build passed, followed by the module-import test (1 test,
  0 failures). Do not symlink `.build` between checkouts: duplicate absolute module-cache paths
  caused a compiler crash. Use a separate cache. Developer ID team `M2TEAF948X` is available.
- `docs/borrowed/` holds the Parakey regions to port (hotkey listener, text insertion, corrections,
  filler removal) with the MIT notice; `parakey-audio-capture-…` is reference-only for two invariants.

## Verified API surface (from the checked-out sources, 2026-09-29)
**speech-swift / Qwen3ASR** — `public extension Qwen3ASRModel { static func fromPretrained(modelId: String = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", cacheDir: URL? = nil, offlineMode: Bool = false, progressHandler: ((Double, String) -> Void)? = nil) async throws -> Qwen3ASRModel }`; 1.7B = `"aufklarer/Qwen3-ASR-1.7B-MLX-8bit"` (`ASRModelSize.large`); `transcribe(audio:sampleRate:options: Qwen3DecodingOptions) -> String` and `transcribeCheckingCancellation(audio:sampleRate:options:) throws -> String`; `Qwen3DecodingOptions()` has `maxTokens`, `language`, `context`. Cache `~/Library/Caches/qwen3-speech/` (override `QWEN3_CACHE_DIR`).
**moonshine-swift / MoonshineVoice** — `Transcriber(modelPath: String, modelArch: ModelArch = .base, options: [TranscriberOption]? = nil, spellingModelPath: String? = nil) throws`; `createStream(updateInterval: TimeInterval = 0.5, flags: UInt32 = 0, transcribeFlags: UInt32 = 0) throws -> Stream`; `Stream.start()/stop()/close()`, `addAudio(_ audioData: [Float], sampleRate: Int32 = 16000) throws`, `addListener((TranscriptEvent) throws -> Void)`; events `LineStarted`, `LineUpdated`, `LineTextChanged`, `LineCompleted` (`line.text`, `startTime`, `duration`, `lineId`), `TranscriptError` (`error`); `Transcriber.setKeyterms([String]) throws` (no commas), `setContext(_:maxTerms:)`, `transcribeWithoutStreaming(audioData:sampleRate:flags:) throws -> Transcript`; `ModelArch`: `.tiny .base .tinyStreaming .baseStreaming .smallStreaming .mediumStreaming`; `AssetDownloader().ensureModelPresent(root: URL, spec: .stt(language:modelArch:includeSpelling:includeWordTimestamps:), onProgress:) async throws -> URL`.

## Facts the plan relies on
- Right-Option is a modifier: the hotkey tap watches `flagsChanged` and diffs `.maskAlternate`
  against the physical keycode (61 right, 58 left) — `docs/borrowed/parakey-hotkey-listener.swift`.
- Paste = pasteboard snapshot → write → ⌘V `CGEvent` → restore after ~150 ms; refuse when
  `IsSecureEventInputEnabled()` — `docs/borrowed/parakey-text-insertion.swift`.
- `AVAudioConverter` input block must return `.noDataNow`, never `.endOfStream` (spec §2.3).
- Footprint target ≈ 2.5–3 GB with the 8-bit 1.7B Qwen3 weights; on this 36 GB machine that's fine.
  If a 5-bit 1.7B variant appears in speech-swift's registry, prefer it (1.32 % WER, 1.9 GB).

## Next steps (in order)
1. Apply the Moonshine-only design/dependency amendment, then continue Tasks 3–11 in
   `docs/superpowers/plans/2026-09-29-said-implementation.md` (Tasks 1–2 complete) task by task
   (subagent-driven development recommended; TDD; branch per task; PR to `main`).
2. Hardware/TCC verification is Scott's: `docs/SMOKE.md`. Report "needs smoke", never "done".
3. First real-hardware milestone: Task "Dictation end-to-end" — hold ⌥ in Notes, see live words,
   release, text pasted, clipboard restored.

## Gotchas
- First `swift build` after a clean checkout recompiles MLX Metal shaders: several minutes.
- SwiftPM builds a CLI; the menu-bar app + TCC identity need the xcodegen `.app` (plan task).
- Ad-hoc-signed dev builds reset TCC grants: `tccutil reset ListenEvent org.tvw.said` etc.
- GitHub shows `license=null` until its detector re-scans; `LICENSE` is plain MIT, third-party
  attribution lives in `NOTICE`.
- The Helper session that created this repo does not implement here; it hands off.
