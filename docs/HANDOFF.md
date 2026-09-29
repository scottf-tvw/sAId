# HANDOFF — sAId (updated 2026-09-29)

For the agent taking over. Read `CLAUDE.md` first, then the spec, then the plan.

## Where things stand
- **Repo**: `github.com/scottf-tvw/sAId` (public, MIT), local `/Volumes/Work/GitDev/sAId`, branch `main`.
- **Design approved** through §1 by Scott on 2026-09-29; §2–§10 follow the same session's decisions.
  `docs/superpowers/specs/2026-09-29-said-dictation-design.md`. Decision table in §0 — do not reopen.
- **Skeleton builds**: `swift build` → "Build complete! (40.49s)" on Swift 6.3.3 / Xcode 26.6 /
  macOS 27.0 (M4 Max 36 GB), 2026-09-29. Both engine packages resolve and link:
  - `speech-swift` @ `main` (`1e6e0e5`), product `Qwen3ASR` — plus its `SpeechCore.xcframework` v0.0.14
  - `moonshine-swift` **0.1.5**, product `MoonshineVoice` — plus `Moonshine.xcframework` v0.1.5
  - transitive: mlx-swift 0.31.6, mlx-swift-lm 3.31.4, hummingbird, swift-nio…
  `Package.resolved` is committed. **Pin `speech-swift` to that commit** in Task 1 of the plan
  (`revision:` instead of `branch:`) so builds stay reproducible.
- No app code yet: `Sources/sAId/main.swift` is a one-line skeleton that imports both packages.
- `docs/borrowed/` holds the Parakey regions to port (hotkey listener, text insertion, corrections,
  filler removal) with the MIT notice; `parakey-audio-capture-…` is reference-only for two invariants.

## Verified API surface (from the checked-out sources, 2026-09-29)
**speech-swift / Qwen3ASR** — `Qwen3ASRModel.fromPretrained(…)`; variants `.small` (0.6B →
`aufklarer/Qwen3-ASR-0.6B-MLX-4bit`) and `.large` (1.7B → `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`);
`transcribe(audio:sampleRate:)` on 16 kHz mono `[Float]`; `transcribeCheckingCancellation(…)`.
Cache `~/Library/Caches/qwen3-speech/` (override `QWEN3_CACHE_DIR`); `offlineMode`. Exact
signatures are quoted in the plan's engine task.
**moonshine-swift / MoonshineVoice** — `Transcriber(modelPath:modelArch:…)` with
`ModelArch.mediumStreaming`; `createStream(…)` / `getDefaultStream()` → `Stream`; `Stream.start()`,
`addAudio(_:sampleRate: 16000)`, `addListener { (TranscriptEvent) in … }`, `stop()`, `close()`;
events `LineStarted`, `LineUpdated`, `LineTextChanged`, `LineCompleted`, `TranscriptError`, each with
`line: TranscriptLine`; `Transcriber.setKeyterms([String])` (vocabulary boost) and
`setContext(_:)`; `transcribeWithoutStreaming(…)` for batch. Models via
`AssetDownloader.ensureModelPresent(root:spec: .stt(…), onProgress:)`, resumable, atomic.

## Facts the plan relies on
- Right-Option is a modifier: the hotkey tap watches `flagsChanged` and diffs `.maskAlternate`
  against the physical keycode (61 right, 58 left) — `docs/borrowed/parakey-hotkey-listener.swift`.
- Paste = pasteboard snapshot → write → ⌘V `CGEvent` → restore after ~150 ms; refuse when
  `IsSecureEventInputEnabled()` — `docs/borrowed/parakey-text-insertion.swift`.
- `AVAudioConverter` input block must return `.noDataNow`, never `.endOfStream` (spec §2.3).
- Footprint target ≈ 2.5–3 GB with the 8-bit 1.7B Qwen3 weights; on this 36 GB machine that's fine.
  If a 5-bit 1.7B variant appears in speech-swift's registry, prefer it (1.32 % WER, 1.9 GB).

## Next steps (in order)
1. Execute `docs/superpowers/plans/2026-09-29-said-implementation.md` task by task
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
