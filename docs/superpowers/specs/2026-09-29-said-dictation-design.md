# sAId — push-to-talk dictation for Apple Silicon: design

_Status: approved by Scott through §1 on 2026-09-29; §2–§10 written from the same session's
decisions. Owner: Scott Freeman. Implementer: the next agent (see `CLAUDE.md`, `docs/HANDOFF.md`)._

## 0. Decisions (Scott, 2026-09-29)

| Decision | Ruling |
|---|---|
| Form | **Standalone** macOS menu-bar app. No sidecar, no Electron, no IPC. (The hAIvd-Assist dictation sidecar was abandoned because the sidecar lifecycle broke; that whole class of failure is designed out.) |
| Feel | **Both**: live words in a floating HUD while the key is held; the accurate final text is what gets pasted on release. |
| Final engine | **Qwen3-ASR 1.7B** via `speech-swift` (Apache-2.0). Chosen on accuracy: 1.32 % WER vs Whisper large-v3-turbo 1.71 % vs Parakeet v3 2.37 % (LibriSpeech-clean, M5 Pro). Parakeet was rejected by Scott on error rate. |
| Preview engine | **Moonshine `mediumStreaming`** via `moonshine-swift` (Scott's explicit choice). Preview text is never pasted, so its accuracy class is irrelevant; its streaming latency is the point. |
| Starting point | **Fresh code.** Borrow only Parakey's hotkey listener and text-insertion logic (MIT, attributed — `docs/borrowed/`). Parakey's audio-capture invariants are carried as written constraints, not ported code. |
| Hotkey | Right Option (⌥, keycode 61) press-and-hold, Esc cancels; configurable. |
| Residency | Both engines loaded at launch and kept resident (~2.5 GB on a 36 GB Mac Studio). No idle-unload / memory-pressure machinery in v1. |
| Post-processing | Deterministic only in v1: user corrections dictionary + filler removal + first-letter casing. **No LLM cleanup pass in v1** (candidate for later via the Studio local model or GX10). |
| Platform | macOS 15+ (speech-swift's MLState/ANE requirement); developed and used on macOS 27, M4 Max 36 GB. |
| Name / repo | `sAId` — `github.com/scottf-tvw/sAId`, **public, MIT** ("nothing proprietary about it" — Scott), `/Volumes/Work/GitDev/sAId`. Bundle id `org.tvw.said`. |

## 1. Goals and non-goals

**Goals**
1. Hold ⌥, speak, release → correct text appears at the cursor in whatever app is frontmost, with the previous clipboard intact.
2. While holding, a floating HUD shows that it is hearing you (live words), so you never wonder whether it's working.
3. Accuracy on Scott's vocabulary (broadcast, IT, legislative names) — the corrections dictionary is a first-class feature, not a hidden pref.
4. Fully on-device; works with no network after the models are cached.
5. Boring reliability: no crashes, no stuck state, no lost clipboard; every failure shows in the HUD and the log.

**Non-goals (v1)**: file transcription, meeting recording, TTS, LLM rewriting, per-app prompts, auto-update, App Store distribution, multi-language (English only; both engines are configured `en`).

## 2. Architecture

One Swift 6 process: `MenuBarExtra` status item + a non-activating floating `NSPanel` HUD + a Settings window + a History window. Two ASR engines behind one protocol.

```
 ⌥ down (flagsChanged via CGEventTap)                      Esc → cancel
        │
        ▼
 AudioCapture ── AVAudioEngine input tap ─▶ AVAudioConverter ─▶ 16 kHz mono Float32 chunks
        │ (serial audio queue, never the main actor)
        ├──▶ PreviewEngine  (Moonshine Stream.addAudio) ── LineTextChanged ──▶ HUD live text
        └──▶ UtteranceBuffer.append
 ⌥ up
        ▼
 FinalEngine.transcribe(UtteranceBuffer)  (Qwen3-ASR 1.7B; ≈0.3 s for 10 s of speech)
        ▼
 PostProcess (corrections → fillers → casing)
        ▼
 Inserter (secure-input check → pasteboard write → ⌘V CGEvent → restore pasteboard)
        ▼
 History.append · HUD shows final text briefly · hides
```

### 2.1 Modules

| Module | Responsibility | Notes |
|---|---|---|
| `App` (`sAIdApp.swift`) | `MenuBarExtra`, wiring, lifecycle, model-loading gate | SwiftUI |
| `Hotkey` | `CGEventTap` on `flagsChanged` + `keyDown`/`keyUp`; detects Right-Option press/release by diffing the `.maskAlternate` flag with the physical keycode; Esc while held = cancel; re-enables the tap on `tapDisabledByTimeout` | Ported from Parakey (`docs/borrowed/parakey-hotkey-listener.swift`), MIT notice kept |
| `AudioCapture` | Owns `AVAudioEngine`; installs an input tap at the hardware format; converts to 16 kHz mono Float32 with `AVAudioConverter`; delivers `[Float]` chunks on a serial `DispatchQueue` | **Fresh.** Invariants in §2.3 |
| `Engine` (protocol) | `protocol FinalTranscriber { func transcribe(_ pcm16k: [Float]) async throws -> String }` and `protocol PreviewTranscriber { func start() throws; func feed(_ pcm16k: [Float]); func stop(); var lines: AsyncStream<PreviewLine> { get } }` | Fakes conform in tests |
| `Qwen3FinalEngine` | `Qwen3ASRModel.fromPretrained(...)` (1.7B), `transcribe(audio:sampleRate: 16000)` | `speech-swift` product `Qwen3ASR`. Downloads to `~/Library/Caches/qwen3-speech/` on first run; `offlineMode: true` thereafter |
| `MoonshinePreviewEngine` | `MoonshineVoice.Transcriber(modelPath:modelArch: .mediumStreaming)` + `Stream`; `addAudio(_:sampleRate: 16000)` per chunk; listeners for `LineTextChanged` / `LineCompleted` / `TranscriptError` | Model fetched with `ensureModelPresent(root:spec: .stt("en", .mediumStreaming, …))` into `~/Library/Application Support/sAId/models/moonshine/` |
| `PostProcess` | Corrections dictionary (whole-word, case-insensitive, user-editable JSON), filler removal (`um`, `uh`, `you know`, …), first-letter capitalization, trailing-space option | Logic adapted from Parakey's small helpers (attributed); rewritten with tests |
| `Inserter` | Refuse if `IsSecureEventInputEnabled()`; snapshot pasteboard items; write text; post ⌘V via `CGEvent` (`.combinedSessionState`); after 150 ms restore the snapshot; fallback: Unicode key-event typing for apps that ignore paste | Ported from Parakey (`docs/borrowed/parakey-text-insertion.swift`), MIT notice kept |
| `HUD` | `NSPanel` (`.nonactivatingPanel`, `.floating`, ignores mouse, no key focus), bottom-center of the screen containing the mouse; states in §4 | Fresh, SwiftUI content |
| `Permissions` | Microphone (`AVCaptureDevice.requestAccess`), Input Monitoring (`CGPreflightListenEventAccess`/`CGRequestListenEventAccess`), Accessibility (`AXIsProcessTrustedWithOptions`); first-run checklist | Fresh |
| `Settings` | Hotkey keycode, input device, corrections editor, filler toggle, model status/reset | SwiftUI, `UserDefaults` + JSON files in Application Support |
| `History` | Last 50 transcripts (text, timestamp, target app), copy-to-clipboard, clear | JSON file; no database |
| `Log` | `os.Logger` subsystem `org.tvw.said`; a "Copy diagnostics" menu item | |

### 2.2 Dictation state machine (the heart; unit-tested with fake engines)

```
idle ──⌥down──▶ listening ──⌥up──▶ finalizing ──text──▶ inserting ──ok──▶ shown(600 ms) ──▶ idle
   ▲                │ Esc                │ error/empty          │ error
   └────────────────┴────────────────────┴──────────────────────┴──▶ error(2 s) ──▶ idle
```
- `listening`: capture running; every chunk goes to the preview engine and the utterance buffer; HUD shows live text.
- `⌥up` before 250 ms of audio → treated as a tap, not dictation: back to `idle`, no engine call (prevents accidental pastes).
- `finalizing`: capture stopped, preview stopped; final engine runs on the buffer; HUD freezes the preview and shows a spinner.
- Empty/whitespace final text → `idle` with a soft HUD "nothing heard".
- A second `⌥down` during `finalizing` is queued as a new utterance only after `inserting` completes (no overlap).
- Cap: 120 s of audio per utterance; at the cap the HUD warns and the state moves to `finalizing` automatically.

### 2.3 Audio invariants (from Parakey's hard-won lessons — write them as tests and comments)
1. The `AVAudioConverter` input block returns `.noDataNow` when it has no buffer, **never** `.endOfStream` (which puts the converter in a terminal state; every later press captures silence).
2. `AudioCapture` is **not** `@MainActor`; the tap fires on an audio thread; hopping to the main actor inside the tap traps under strict concurrency. Deliver chunks via a serial queue → `AsyncStream`.
3. Never run transcription inside the tap; the tap must return promptly.
4. Resources are loaded via `Bundle.main`, never `Bundle.module` (SwiftPM's resource bundle has no `Info.plist` and breaks `codesign --deep`).
5. Re-create the engine/tap on `AVAudioEngineConfigurationChange` (device switch) and after sleep/wake.

### 2.4 Concurrency model
- `DictationController` is an `actor` owning the state machine; UI observes a `@MainActor` view model fed by an `AsyncStream<DictationState>`.
- Engines are actors; `FinalTranscriber.transcribe` is awaited from the controller.
- Swift 6 strict concurrency on; no `@unchecked Sendable` outside the engine adapters that wrap third-party types.

## 3. Engines and models

| | Final: Qwen3-ASR 1.7B | Preview: Moonshine mediumStreaming |
|---|---|---|
| Package | `speech-swift` (`Qwen3ASR`), Apache-2.0, macOS 15+ | `moonshine-swift` v0.1.5 (`MoonshineVoice`), macOS 13+, binary `Moonshine.xcframework` |
| Backend | MLX + CoreML hybrid (GPU/ANE) | Moonshine C++ runtime (CPU) |
| Input | 16 kHz mono Float32, whole utterance | 16 kHz mono Float32, incremental `addAudio` |
| Output | final string | `LineTextChanged` (partial) / `LineCompleted` events |
| Model source | Hugging Face → `~/Library/Caches/qwen3-speech/` | Moonshine catalog → `~/Library/Application Support/sAId/models/moonshine/` |
| Footprint | ≈1.9 GB resident (5-bit) | small (245M params); CPU cost ≈0.27 s per second of audio |
| Language | `en` | `en` |

Rules: both engines load at launch (HUD shows "loading models…"; dictation is refused until both are ready); models are cached once and never re-downloaded on the hot path (`offlineMode` after first success); a preview-engine failure degrades to "no live text" and never blocks the final path; a final-engine failure surfaces as a HUD error with the preview text offered in History (never pasted automatically).

**Verify during implementation (not open decisions):** the exact `fromPretrained` parameter that selects the 1.7B variant and its quantization; Moonshine's `Transcriber` init signature for the streaming arch; the `Stream` update interval that gives the best HUD feel (start at 0.3 s).

## 4. HUD and menu UX

HUD (bottom-center, 44 pt pill, dark translucent, never takes focus):
| State | Shows |
|---|---|
| listening | mic glyph pulsing + live preview text (last ~12 words, trailing) |
| finalizing | preview frozen, small spinner |
| shown | final text for 600 ms, then fades |
| error | red text 2 s ("Secure input field", "Model not ready", "Paste failed — text copied to clipboard") |
| loading | "Loading models…" (only until first ready) |

Menu bar: status glyph (idle / listening / models loading); items: **Dictation on/off**, **Last transcript → copy**, **History…**, **Settings…**, **Copy diagnostics**, **Quit**. First run opens the permissions checklist (three rows with "Open System Settings" buttons; the app polls until green).

## 5. Post-processing

Order: corrections → filler removal → casing → trailing space (opt-in). Corrections file `~/Library/Application Support/sAId/corrections.json`: `[{"from":"invintus","to":"Invintus"}, …]`, whole-word, case-insensitive match, replacement keeps the user's casing; editable in Settings (add/edit/delete, import/export). Filler list is a fixed default plus user additions. Never alter numbers, URLs, or code-looking tokens (contain `/`, `_`, `.` between letters).

## 6. Permissions, signing, packaging

- Bundle id `org.tvw.said`; `.app` built with **xcodegen** (`project.yml`) from the SwiftPM targets (a plain SPM executable cannot host a menu-bar app with TCC-stable identity).
- **Developer ID** signing + hardened runtime, entitlement `com.apple.security.device.audio-input`; notarize for Gatekeeper comfort (`scripts/release.sh`). Same identity pipeline Scott used for hAIvd-Assist.
- TCC: Microphone, Input Monitoring, Accessibility. Stable signature ⇒ grants persist across builds; an ad-hoc dev build resets them (document `tccutil reset` in `CLAUDE.md`).
- Install: `make install` → `/Applications/sAId.app`. Login item toggle via `SMAppService` is a v1.1 item.

## 7. Failure modes

| Situation | Behaviour |
|---|---|
| Frontmost field is secure input (password) | Refuse; HUD "Secure input field"; nothing pasted; text kept in History |
| Paste ignored by the target app | Fallback Unicode typing; if that fails, text stays on the clipboard and HUD says so |
| Preview engine throws | Live text stops; final path unaffected; logged |
| Final engine throws / not loaded | HUD error; utterance preview kept in History; no paste |
| Mic device disappears mid-utterance | Cancel to idle with HUD error; capture re-armed on next press |
| Tap disabled by timeout | Re-enabled immediately (Parakey pattern); logged |
| App loses Input Monitoring / Accessibility (TCC reset) | Menu glyph turns amber; first-run checklist reopens on next press |
| Sleep/wake | Audio engine and tap rebuilt on wake |

## 8. Testing strategy

- **Unit (XCTest, no hardware)**: state machine with fake engines (all transitions in §2.2 incl. tap-vs-hold, cancel, cap, overlap); `PostProcess` (corrections, fillers, casing, protected tokens); `Inserter` pure parts (pasteboard snapshot/restore diffing, fallback decision); `AudioCapture` converter block (`.noDataNow` invariant) with a synthetic buffer; HUD state reducer.
- **Engine contract tests (opt-in, need models)**: transcribe three bundled WAVs through each engine; assert non-empty and a WER ceiling; skipped with `XCTSkip` when models aren't cached.
- **Bench script** (`scripts/bench.sh`): Scott's own 20-sentence jargon set as WAVs → WER per engine; this is how engine choices get revisited.
- **Manual smoke matrix** (`docs/SMOKE.md`): paste into Terminal, Safari field, Slack, Mail, VS Code, Notes; clipboard restored each time; secure-input refusal in a password field; sleep/wake; device switch.

## 9. Repo layout

```
Package.swift            SPM: sAId executable + tests; deps speech-swift, moonshine-swift
project.yml              xcodegen → sAId.xcodeproj (.app bundle, signing)   [plan task]
Sources/sAId/            App, Hotkey, AudioCapture, Engines, PostProcess, Inserter, HUD, Permissions, Settings, History, Log
Tests/sAIdTests/
Resources/               menu-bar icon, sounds, default corrections/fillers
docs/superpowers/specs/  this document
docs/superpowers/plans/  implementation plan
docs/borrowed/           Parakey reference regions + MIT license
docs/HANDOFF.md          current state for the next agent
scripts/                 bench.sh, release.sh
```

## 10. Open questions (owner: Scott)
1. Should the corrections dictionary also feed Moonshine's optional spelling model (`spellingModelPath`) so the preview shows the corrected names too? (Nice-to-have; v1.1.)
2. LLM cleanup pass (Studio local model / GX10) once the deterministic pass has been used for a while — what should it be allowed to change?
3. Login item by default?

## 11. Evidence trail
- Engine numbers: soniqo benchmarks (M5 Pro, LibriSpeech-clean 200 utts): Qwen3-ASR 1.7B MLX 5-bit 1.32 % / RTF 0.027 / 1.92 GB; WhisperKit large-v3-turbo 1.71 %; Parakeet v3 2.37 %. Moonshine streaming-medium card: LS-clean 2.08, GigaSpeech 9.46, AMI 19.03, "can hallucinate … on short or noisy segments".
- `speech-swift` README: `import Qwen3ASR`, `Qwen3ASRModel.fromPretrained()`, `transcribe(audio:sampleRate:)`, cache `~/Library/Caches/qwen3-speech/`, macOS 15+.
- `moonshine-swift` @ main: `Package.swift` (binaryTarget v0.1.5, macOS 13), `ModelArch` (`.mediumStreaming`), `Stream` (`addAudio`, listeners, `LineTextChanged`/`LineCompleted`), `MicTranscriber` (owns its own mic — not used), `AssetDownloader.ensureModelPresent(root:spec:)`.
- Parakey provenance: MIT © 2026 Richard Courtman, `github.com/rcourtman/parakey`; fork commit `TVWIT/hAIvd-Assist@5b0f9a7`; the hybrid final+partials HUD existed there as `91a89e1` (Parakeet on both sides).
- Apple: `SpeechModule` conformers are Apple-only (`SpeechTranscriber`, `DictationTranscriber`, `SpeechDetector`); nothing new in macOS 27 for third-party models — hence no Apple-framework path for Moonshine.
