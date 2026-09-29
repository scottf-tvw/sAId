# sAId — push-to-talk dictation for Apple Silicon: design

_Status: approved design, amended by Scott on 2026-09-29 to use Moonshine for both preview and final transcription. Owner: Scott Freeman. Current implementation state: `docs/HANDOFF.md`._

## 0. Decisions (Scott, 2026-09-29)

| Decision | Ruling |
|---|---|
| Form | **Standalone** macOS menu-bar app. No sidecar, no Electron, no IPC. (The hAIvd-Assist dictation sidecar was abandoned because the sidecar lifecycle broke; that whole class of failure is designed out.) |
| Feel | **Both**: live words in a floating HUD while the key is held; the accurate final text is what gets pasted on release. |
| Final engine | **Moonshine `mediumStreaming`** via `moonshine-swift` 0.1.5. Scott changed the original Qwen choice during implementation. On release, transcribe the complete captured utterance using the same resident model; only this completed result is postprocessed and pasted. |
| Preview engine | The same **Moonshine `mediumStreaming`** model, using a fresh streaming session per utterance. Live partials are display-only. |
| Starting point | **Fresh code.** Borrow only Parakey's hotkey listener and text-insertion logic (MIT, attributed — `docs/borrowed/`). Parakey's audio-capture invariants are carried as written constraints, not ported code. |
| Hotkey | Right Option (⌥, keycode 61) press-and-hold, Esc cancels; configurable. |
| Residency | One Moonshine model loaded at launch and kept resident. Native calls are serialized by an actor. No idle-unload / memory-pressure machinery in v1. Measure footprint during smoke testing. |
| Post-processing | Deterministic only in v1: user corrections dictionary + filler removal + first-letter casing. **No LLM cleanup pass in v1** (candidate for later via the Studio local model or GX10). |
| Platform | macOS 15+ on Apple Silicon; retain this floor for Swift concurrency and application APIs. |
| Name / repo | `sAId` — `github.com/scottf-tvw/sAId`, **public, MIT** ("nothing proprietary about it" — Scott), `/Volumes/Work/GitDev/sAId`. Bundle id `org.tvw.said`. |

## 1. Goals and non-goals

**Goals**
1. Hold ⌥, speak, release → correct text appears at the cursor in whatever app is frontmost, with the previous clipboard intact.
2. While holding, a floating HUD shows that it is hearing you (live words), so you never wonder whether it's working.
3. Accuracy on Scott's vocabulary (broadcast, IT, legislative names) — the corrections dictionary is a first-class feature, not a hidden pref.
4. Fully on-device; works with no network after the models are cached.
5. Boring reliability: no crashes, no stuck state, no lost clipboard; every failure shows in the HUD and the log.

**Non-goals (v1)**: file transcription, meeting recording, TTS, LLM rewriting, per-app prompts, auto-update, App Store distribution, multi-language (English only; Moonshine is configured `en`).

## 2. Architecture

One Swift 6 process: `MenuBarExtra` status item + a non-activating floating `NSPanel` HUD + a Settings window + a History window. One resident Moonshine engine serves separate preview and final-transcription protocols.

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
 FinalEngine.transcribe(UtteranceBuffer)  (Moonshine, after preview stops)
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
| `Engine` (protocol) | `protocol FinalTranscriber { func transcribe(_ pcm16k: [Float]) async throws -> String }` and `protocol PreviewTranscriber { func start() async throws -> AsyncThrowingStream<PreviewLine, Error>; func feed(_ pcm16k: [Float]) async throws; func stop() async }` | Fakes conform in tests |
| `MoonshineEngine` final role | `Transcriber.transcribeWithoutStreaming(audioData:sampleRate:flags:)` on the complete utterance after streaming stops | Same resident native transcriber; serialized actor access. Join completed transcript lines in order. Never substitute a preview after final failure. |
| `MoonshineEngine` preview role | `MoonshineVoice.Transcriber(modelPath:modelArch: .mediumStreaming)` + `Stream`; `addAudio(_:sampleRate: 16000)` per chunk; listeners for `LineTextChanged` / `LineCompleted` / `TranscriptError` | Model fetched with `ensureModelPresent(root:spec: .stt("en", .mediumStreaming, …))` into `~/Library/Application Support/sAId/models/moonshine/` |
| `PostProcess` | Corrections dictionary (whole-word, case-insensitive, user-editable JSON), filler removal (`um`, `uh`, `you know`, …), first-letter capitalization, trailing-space option | Logic adapted from Parakey's small helpers (attributed); rewritten with tests |
| `Inserter` | Refuse if `IsSecureEventInputEnabled()`; snapshot pasteboard items; write text; post ⌘V via `CGEvent` (`.combinedSessionState`); after 150 ms restore the snapshot; selectable Unicode typing for apps that ignore paste; automatic fallback only for known pre-delivery setup failures | Ported from Parakey (`docs/borrowed/parakey-text-insertion.swift`), MIT notice kept |
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
- `MoonshineEngine` is one actor serving both protocols. Its resident native model is shared, and final transcription runs only after its streaming session stops.
- Swift 6 strict concurrency on; no `@unchecked Sendable` outside the engine adapters that wrap third-party types.

## 3. Engine and model

Use `moonshine-swift` **exactly 0.1.5**, product `MoonshineVoice`, model arch `.mediumStreaming`, language `en`. Remove Qwen, speech-swift, MLX and their transitive dependencies from this app.

Scott confirmed **English Medium Streaming** using the [current model list](https://moonshine-voice.readthedocs.io/en/latest/models/available-models/#current-models). This is the 245-million-parameter English model and maps to `.mediumStreaming` in Swift. Its published aggregate WER is not interchangeable with a single-dataset score or Scott's own vocabulary results.

One `MoonshineEngine` actor owns one resident `Transcriber`. It conforms to the existing async `PreviewTranscriber` and `FinalTranscriber` protocols. Start a fresh native `Stream` and fresh `AsyncThrowingStream<PreviewLine, Error>` for each press; keep the model resident. Aggregate engine line IDs into an ordered utterance preview. Surface thrown stop failures and synchronous native `TranscriptError` events through the throwing preview stream before finishing it; retain the resident model for the final pass. Begin with an update interval of 0.3 seconds. Release drains capture, stops the preview, and invokes `transcribeWithoutStreaming` on the full 16 kHz mono Float32 buffer. A final pass failure retains the preview in History but never pastes it.

Load at launch and show model progress; refuse capture until the model is ready. A streaming-session failure degrades live text without disabling final transcription while the underlying model remains loaded. A model-load failure keeps dictation disabled and offers Retry. Settings show readiness, progress, cache location, and an explicit model-reset action with local confirmation; reset affects only this app's model files.

Cache: `~/Library/Application Support/sAId/models/moonshine/`. Obtain the required files from `AssetDownloader`'s native catalog using `.stt(language: "en", modelArch: .mediumStreaming)`. If the public CDN fails, use the exact corresponding files from the official `moonshine-ai/moonshine-voice-assets` Hugging Face mirror. Validate sizes and available checksums, download atomically, preserve complete cached files, and never require credentials. Offline launch with a complete cache must work.

The current catalog contains adapter, encoder, decoder, cross-KV, frontend, tokenizer, and streaming configuration files. Do not hard-code assumptions about its optional spelling or word-timestamp models. Neither optional model is required in v1.

Accuracy and latency are measured on the bundled LibriSpeech fixtures and Scott's eventual recorded jargon corpus. The engine change follows Scott's preference; it is not an unmeasured claim that one model has universally lower WER.

## 4. HUD and menu UX

HUD (bottom-center, 44 pt pill, dark translucent, never takes focus):
| State | Shows |
|---|---|
| listening | mic glyph pulsing + live preview text (last ~12 words, trailing) |
| finalizing | preview frozen, small spinner |
| shown | final text for 600 ms, then fades |
| error | red text 2 s ("Secure input field", "Model not ready", "Paste failed — copy from History") |
| loading | "Loading models…" (only until first ready) |

Menu bar: status glyph (idle / listening / models loading); items: **Dictation on/off**, **Last transcript → copy**, **History…**, **Settings…**, **Copy diagnostics**, **Quit**. First run opens the permissions checklist (three rows with "Open System Settings" buttons; the app polls until green).

## 5. Post-processing

Order: corrections → filler removal → casing → trailing space (opt-in). Corrections file `~/Library/Application Support/sAId/corrections.json`: `[{"from":"invintus","to":"Invintus"}, …]`, whole-word, case-insensitive match, replacement keeps the user's casing; editable in Settings (add/edit/delete, import/export). Filler list is a fixed default plus user additions. Never alter numbers, URLs, or code-looking tokens (contain `/`, `_`, `.` between letters).

## 6. Permissions, signing, packaging

- Bundle id `org.tvw.said`; `.app` built with **xcodegen** (`project.yml`) from the Swift sources and the pinned Moonshine package (a plain SPM executable cannot host a menu-bar app with TCC-stable identity).
- **Developer ID** signing + hardened runtime, entitlement `com.apple.security.device.audio-input`; notarize for Gatekeeper comfort (`scripts/release.sh`). Same identity pipeline Scott used for hAIvd-Assist.
- TCC: Microphone, Input Monitoring, Accessibility. Stable signature ⇒ grants persist across builds; an ad-hoc dev build resets them (document `tccutil reset` in `CLAUDE.md`).
- Install: `make install` → `/Applications/sAId.app`. Login item toggle via `SMAppService` is a v1.1 item.

## 7. Failure modes

| Situation | Behaviour |
|---|---|
| Frontmost field is secure input (password) | Refuse; HUD "Secure input field"; nothing pasted; text kept in History |
| Paste ignored by the target app | Offer selectable direct Unicode typing. Automatic fallback is allowed only for failures known to occur before event delivery; keyboard posting has no universal acceptance receipt. Preserve the original/newer clipboard and keep the transcript in History with Copy. |
| Preview engine throws | Live text stops; final path unaffected; logged |
| Final engine throws / not loaded | HUD error; utterance preview kept in History; no paste |
| Mic device disappears mid-utterance | Cancel to idle with HUD error; capture re-armed on next press |
| Tap disabled by timeout | Re-enabled immediately (Parakey pattern); logged |
| App loses Input Monitoring / Accessibility (TCC reset) | Menu glyph turns amber; first-run checklist reopens on next press |
| Sleep/wake | Audio engine and tap rebuilt on wake |

## 8. Testing strategy

- **Unit (XCTest, no hardware)**: state machine with fake engines (all transitions in §2.2 incl. tap-vs-hold, cancel, cap, overlap); `PostProcess` (corrections, fillers, casing, protected tokens); `Inserter` pure parts (pasteboard snapshot/restore diffing, fallback decision); `AudioCapture` converter block (`.noDataNow` invariant) with a synthetic buffer; HUD state reducer.
- **Engine contract tests (opt-in, need models)**: transcribe three bundled WAVs through the preview and final paths; assert non-empty and a WER ceiling; skipped with `XCTSkip` when models aren't cached.
- **Bench script** (`scripts/bench.sh`): Scott's own 20-sentence jargon set as WAVs → WER and latency for the final path, with optional preview-path measurements; this is how model choices get revisited.
- **Manual smoke matrix** (`docs/SMOKE.md`): paste into Terminal, Safari field, Slack, Mail, VS Code, Notes; clipboard restored each time; secure-input refusal in a password field; sleep/wake; device switch.

## 9. Repo layout

```
Package.swift            SPM: sAId executable + tests; dependency moonshine-swift
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
1. Should the corrections dictionary also feed Moonshine's optional spelling model (`spellingModelPath`) so the preview shows the corrected names too? (Nice-to-have; v1.1. Basic keyterm biasing without the spelling model may use the existing corrections.)
2. LLM cleanup pass (Studio local model / GX10) once the deterministic pass has been used for a while — what should it be allowed to change?
3. Login item by default?

## 11. Evidence trail

- Scott's implementation-session amendment on 2026-09-29: Moonshine supplies both live preview and final transcription; Qwen is removed.
- `moonshine-swift` 0.1.5 checked-out sources: `Transcriber.transcribeWithoutStreaming`, `createStream`, `.mediumStreaming`, `Stream.stop` final updates, `AssetDownloader.isModelPresent` and `ensureModelPresent`.
- Official sources: [Swift package](https://github.com/moonshine-ai/moonshine-swift), [native API](https://github.com/moonshine-ai/moonshine/blob/main/core/moonshine-c-api.h), [asset mirror](https://huggingface.co/moonshine-ai/moonshine-voice-assets).
- The original Qwen comparison is historical and superseded by the amendment; do not reuse it as a requirement or an accuracy conclusion.
- Parakey provenance: MIT © 2026 Richard Courtman, `github.com/rcourtman/parakey`; fork commit `TVWIT/hAIvd-Assist@5b0f9a7`. Retain notices in derived hotkey, insertion, and text helper code.
