# sAId Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone macOS menu-bar app: hold Right-Option, speak, release → Qwen3-ASR text is pasted at the cursor; a floating HUD shows Moonshine live words while holding.

**Architecture:** One Swift 6 process. A pure `DictationReducer` (state + event → state + effects) drives everything; a `DictationController` actor executes effects against `AudioCapture`, two engine adapters behind protocols, `PostProcess`, and `TextInserter`. UI (menu bar, HUD panel, Settings, History) observes a `@MainActor` view model. No sidecar, no IPC, both engines resident.

**Tech Stack:** Swift 6.1 tools / Swift 6.3 toolchain, SwiftUI + AppKit, AVFoundation, CoreGraphics event taps, `speech-swift` (`Qwen3ASR`, MLX+CoreML), `moonshine-swift` 0.1.5 (`MoonshineVoice`), XCTest, xcodegen 2.46.

**Spec:** `docs/superpowers/specs/2026-09-29-said-dictation-design.md` — read it first; §0 decisions, §2.2 state machine, §2.3 audio invariants, §7 failure modes.

## Global Constraints

- Platform floor: `platforms: [.macOS(.v15)]` (speech-swift needs MLState). Apple Silicon only.
- Swift 6 strict concurrency on. `@unchecked Sendable` allowed only in the two engine adapters that wrap third-party classes.
- No `print()` in app code; `os.Logger(subsystem: "org.tvw.said", category: …)`.
- Bundle id `org.tvw.said`; app name `sAId`.
- Final engine: `Qwen3ASRModel`, modelId `"aufklarer/Qwen3-ASR-1.7B-MLX-8bit"`. Preview engine: `Transcriber(modelArch: .mediumStreaming)`. Both `language = "en"`.
- Audio format everywhere past capture: 16 kHz, mono, `[Float]` in −1…1.
- Invariants (spec §2.3): converter block returns `.noDataNow` never `.endOfStream`; `AudioCapture` not `@MainActor`; no transcription inside the tap; `Bundle.main` not `Bundle.module`.
- Never paste when `IsSecureEventInputEnabled()`; always restore the clipboard. Preview text is never pasted.
- Hotkey default: Right Option, keycode 61; Esc cancels. Minimum hold 250 ms; cap 120 s.
- Ported Parakey code keeps the MIT notice line from `docs/borrowed/*.swift` at the top of the file.
- Branch per task (`task/N-short-name`), PR to `main`. Commit messages end with the attribution lines your harness specifies.
- Hardware/TCC checks are Scott's (`docs/SMOKE.md`); report them as "needs smoke".

---

## File structure

```
Package.swift                              (Task 1) pin speech-swift revision; test target
project.yml, Info.plist, sAId.entitlements (Task 10) xcodegen → .app with TCC-stable identity
Sources/sAId/
  App/sAIdApp.swift                        (Task 10) @main, MenuBarExtra, Settings scene
  App/AppDelegate.swift                    (Task 10) owns controller, HUD, hotkey, permissions
  App/AppViewModel.swift                   (Task 10) @MainActor mirror of DictationState
  Core/DictationState.swift                (Task 2) state + event + effect enums
  Core/DictationReducer.swift              (Task 2) pure reducer
  Core/DictationController.swift           (Task 9) actor: runs effects, owns buffers
  Engines/EngineProtocols.swift            (Task 2) FinalTranscriber, PreviewTranscriber, PreviewLine
  Engines/Qwen3FinalEngine.swift           (Task 8)
  Engines/MoonshinePreviewEngine.swift     (Task 7)
  Audio/AudioCapture.swift                 (Task 4) AVAudioEngine tap → 16 kHz chunks
  Audio/ConverterFeeder.swift              (Task 4) the .noDataNow input block, testable
  Text/PostProcess.swift                   (Task 3) pipeline
  Text/Corrections.swift                   (Task 3) dictionary model + JSON store
  Text/FillerRemoval.swift                 (Task 3)
  Hotkey/HotkeyDecider.swift               (Task 5) pure press/release/cancel logic
  Hotkey/HotkeyListener.swift              (Task 5) CGEventTap (ported)
  Insert/PasteboardSnapshot.swift          (Task 6) pure snapshot/restore model
  Insert/TextInserter.swift                (Task 6) pasteboard + ⌘V + fallback (ported)
  UI/HUDPanel.swift, UI/HUDView.swift      (Task 9)
  UI/MenuView.swift, UI/SettingsView.swift, UI/HistoryView.swift, UI/PermissionsView.swift (Task 10)
  Support/History.swift                    (Task 10) JSON-backed last-50
  Support/Permissions.swift                (Task 10)
  Support/Log.swift                        (Task 2)
Resources/default-corrections.json, default-fillers.json, MenuBarIcon.png (Task 3/10)
Tests/sAIdTests/…                          one file per module
scripts/bench.sh, scripts/release.sh, docs/SMOKE.md (exists)   (Task 11)
```

---

### Task 1: Pin dependencies, testable layout, green baseline

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/sAId/main.swift` → delete; Create: `Sources/sAId/App/sAIdApp.swift` (placeholder `@main`)
- Modify: `Tests/sAIdTests/SkeletonTests.swift`

**Interfaces:**
- Produces: a package where `swift build` and `swift test` are green and `@testable import sAId` works.

- [ ] **Step 1: Read the pinned speech-swift revision**

Run: `python3 -c "import json;print([p['state']['revision'] for p in json.load(open('Package.resolved'))['pins'] if p['identity']=='speech-swift'][0])"`
Expected: a 40-char SHA beginning `1e6e0e5`.

- [ ] **Step 2: Pin it in Package.swift**

Replace the speech-swift line with (paste the SHA from Step 1):
```swift
.package(url: "https://github.com/soniqo/speech-swift.git", revision: "<sha-from-step-1>"),
```

- [ ] **Step 3: Replace the skeleton entry point**

Delete `Sources/sAId/main.swift`. Create `Sources/sAId/App/sAIdApp.swift`:
```swift
import SwiftUI

@main
struct sAIdApp: App {
    var body: some Scene {
        MenuBarExtra("sAId", systemImage: "mic") {
            Text("sAId — skeleton")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

- [ ] **Step 4: Make the test import the module**

`Tests/sAIdTests/SkeletonTests.swift`:
```swift
import XCTest
@testable import sAId

final class SkeletonTests: XCTestCase {
    func testModuleImports() { XCTAssertTrue(true) }
}
```

- [ ] **Step 5: Build and test**

Run: `swift build && swift test`
Expected: `Build complete!` and `Executed 1 test, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git checkout -b task/1-baseline
git add Package.swift Package.resolved Sources Tests
git commit -m "build: pin speech-swift revision; SwiftUI @main entry; testable baseline"
```

---

### Task 2: Dictation state machine (pure reducer) + engine protocols

**Files:**
- Create: `Sources/sAId/Core/DictationState.swift`, `Sources/sAId/Core/DictationReducer.swift`, `Sources/sAId/Engines/EngineProtocols.swift`, `Sources/sAId/Support/Log.swift`
- Test: `Tests/sAIdTests/DictationReducerTests.swift`

**Interfaces:**
- Produces:
  - `enum DictationState: Equatable { case loadingModels, idle, listening(preview: String, seconds: Double), finalizing(preview: String), shown(final: String), error(String) }`
  - `enum DictationEvent: Equatable { case modelsReady, modelsFailed(String), hotkeyDown, hotkeyUp(heldSeconds: Double), cancel, audio(seconds: Double), preview(String), finalText(String), inserted, insertFailed(String), engineFailed(String), timerFired }`
  - `enum DictationEffect: Equatable { case startCapture, stopCapture, startPreview, stopPreview, runFinal, insert(String), scheduleHide(after: Double), scheduleErrorClear(after: Double), record(String), log(String) }`
  - `struct DictationReducer { static func reduce(_ s: DictationState, _ e: DictationEvent) -> (DictationState, [DictationEffect]) }` with constants `minHoldSeconds = 0.25`, `capSeconds = 120`.
  - `struct PreviewLine: Sendable, Equatable { let text: String; let isFinal: Bool }`
  - `protocol FinalTranscriber: Sendable { func transcribe(_ pcm16k: [Float]) async throws -> String }`
  - `protocol PreviewTranscriber: AnyObject, Sendable { func start() throws; func feed(_ pcm16k: [Float]); func stop(); var lines: AsyncStream<PreviewLine> { get } }`
  - `enum Log { static let app, audio, engine, insert, hotkey: Logger }`

- [ ] **Step 1: Write the failing tests**

`Tests/sAIdTests/DictationReducerTests.swift`:
```swift
import XCTest
@testable import sAId

final class DictationReducerTests: XCTestCase {
    typealias R = DictationReducer

    func testStartsInLoadingAndBecomesIdleWhenModelsReady() {
        let (s, fx) = R.reduce(.loadingModels, .modelsReady)
        XCTAssertEqual(s, .idle); XCTAssertEqual(fx, [])
    }

    func testHotkeyDownWhileLoadingIsRefusedWithError() {
        let (s, fx) = R.reduce(.loadingModels, .hotkeyDown)
        XCTAssertEqual(s, .error("Models still loading"))
        XCTAssertEqual(fx, [.scheduleErrorClear(after: 2)])
    }

    func testHotkeyDownFromIdleStartsCaptureAndPreview() {
        let (s, fx) = R.reduce(.idle, .hotkeyDown)
        XCTAssertEqual(s, .listening(preview: "", seconds: 0))
        XCTAssertEqual(fx, [.startCapture, .startPreview])
    }

    func testPreviewTextUpdatesListening() {
        let (s, _) = R.reduce(.listening(preview: "", seconds: 1), .preview("hello wor"))
        XCTAssertEqual(s, .listening(preview: "hello wor", seconds: 1))
    }

    func testAudioAccumulatesSeconds() {
        let (s, _) = R.reduce(.listening(preview: "x", seconds: 1.0), .audio(seconds: 0.064))
        XCTAssertEqual(s, .listening(preview: "x", seconds: 1.064))
    }

    func testShortTapIsIgnored() {
        let (s, fx) = R.reduce(.listening(preview: "", seconds: 0.1), .hotkeyUp(heldSeconds: 0.1))
        XCTAssertEqual(s, .idle)
        XCTAssertEqual(fx, [.stopCapture, .stopPreview, .log("tap ignored (<0.25s)")])
    }

    func testReleaseAfterHoldFinalizes() {
        let (s, fx) = R.reduce(.listening(preview: "hello", seconds: 2), .hotkeyUp(heldSeconds: 2))
        XCTAssertEqual(s, .finalizing(preview: "hello"))
        XCTAssertEqual(fx, [.stopCapture, .stopPreview, .runFinal])
    }

    func testCapFinalizesAutomatically() {
        let (s, fx) = R.reduce(.listening(preview: "p", seconds: 119.99), .audio(seconds: 0.064))
        XCTAssertEqual(s, .finalizing(preview: "p"))
        XCTAssertEqual(fx, [.stopCapture, .stopPreview, .log("cap reached"), .runFinal])
    }

    func testCancelWhileListeningGoesIdle() {
        let (s, fx) = R.reduce(.listening(preview: "p", seconds: 3), .cancel)
        XCTAssertEqual(s, .idle)
        XCTAssertEqual(fx, [.stopCapture, .stopPreview])
    }

    func testFinalTextInserts() {
        let (s, fx) = R.reduce(.finalizing(preview: "p"), .finalText("Hello world."))
        XCTAssertEqual(s, .finalizing(preview: "p"))
        XCTAssertEqual(fx, [.insert("Hello world.")])
    }

    func testEmptyFinalTextShowsNothingHeard() {
        let (s, fx) = R.reduce(.finalizing(preview: "p"), .finalText("   "))
        XCTAssertEqual(s, .error("Nothing heard"))
        XCTAssertEqual(fx, [.scheduleErrorClear(after: 2)])
    }

    func testInsertedShowsThenHides() {
        let (s, fx) = R.reduce(.finalizing(preview: "p"), .inserted)
        XCTAssertEqual(s, .shown(final: "p"))
        XCTAssertEqual(fx, [.scheduleHide(after: 0.6)])
        let (s2, _) = R.reduce(s, .timerFired)
        XCTAssertEqual(s2, .idle)
    }

    func testInsertFailureKeepsTextInHistoryAndErrors() {
        let (s, fx) = R.reduce(.finalizing(preview: "p"), .insertFailed("Secure input field"))
        XCTAssertEqual(s, .error("Secure input field"))
        XCTAssertEqual(fx, [.record("p"), .scheduleErrorClear(after: 2)])
    }

    func testEngineFailureErrors() {
        let (s, fx) = R.reduce(.finalizing(preview: "p"), .engineFailed("boom"))
        XCTAssertEqual(s, .error("Transcription failed"))
        XCTAssertEqual(fx, [.record("p"), .log("engine: boom"), .scheduleErrorClear(after: 2)])
    }

    func testHotkeyDownDuringFinalizingIsIgnored() {
        let (s, fx) = R.reduce(.finalizing(preview: "p"), .hotkeyDown)
        XCTAssertEqual(s, .finalizing(preview: "p")); XCTAssertEqual(fx, [.log("busy")])
    }

    func testErrorClearsToIdle() {
        let (s, _) = R.reduce(.error("x"), .timerFired)
        XCTAssertEqual(s, .idle)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DictationReducerTests`
Expected: compile errors — `DictationReducer` not found.

- [ ] **Step 3: Implement**

`Sources/sAId/Support/Log.swift`:
```swift
import os

enum Log {
    static let app = Logger(subsystem: "org.tvw.said", category: "app")
    static let audio = Logger(subsystem: "org.tvw.said", category: "audio")
    static let engine = Logger(subsystem: "org.tvw.said", category: "engine")
    static let insert = Logger(subsystem: "org.tvw.said", category: "insert")
    static let hotkey = Logger(subsystem: "org.tvw.said", category: "hotkey")
}
```

`Sources/sAId/Engines/EngineProtocols.swift`:
```swift
struct PreviewLine: Sendable, Equatable {
    let text: String
    let isFinal: Bool
}

protocol FinalTranscriber: Sendable {
    /// Whole-utterance transcription. `pcm16k` is 16 kHz mono in -1…1.
    func transcribe(_ pcm16k: [Float]) async throws -> String
}

protocol PreviewTranscriber: AnyObject, Sendable {
    func start() throws
    func feed(_ pcm16k: [Float])
    func stop()
    /// Partial (`isFinal == false`) and completed lines, in order.
    var lines: AsyncStream<PreviewLine> { get }
}
```

`Sources/sAId/Core/DictationState.swift`:
```swift
enum DictationState: Equatable {
    case loadingModels
    case idle
    case listening(preview: String, seconds: Double)
    case finalizing(preview: String)
    case shown(final: String)
    case error(String)
}

enum DictationEvent: Equatable {
    case modelsReady
    case modelsFailed(String)
    case hotkeyDown
    case hotkeyUp(heldSeconds: Double)
    case cancel
    case audio(seconds: Double)
    case preview(String)
    case finalText(String)
    case inserted
    case insertFailed(String)
    case engineFailed(String)
    case timerFired
}

enum DictationEffect: Equatable {
    case startCapture, stopCapture
    case startPreview, stopPreview
    case runFinal
    case insert(String)
    case scheduleHide(after: Double)
    case scheduleErrorClear(after: Double)
    case record(String)
    case log(String)
}
```

`Sources/sAId/Core/DictationReducer.swift`:
```swift
struct DictationReducer {
    static let minHoldSeconds = 0.25
    static let capSeconds = 120.0
    static let shownSeconds = 0.6
    static let errorSeconds = 2.0

    static func reduce(_ s: DictationState, _ e: DictationEvent) -> (DictationState, [DictationEffect]) {
        switch (s, e) {
        case (.loadingModels, .modelsReady):
            return (.idle, [])
        case (.loadingModels, .modelsFailed(let why)):
            return (.error("Models failed: \(why)"), [.log("models: \(why)")])
        case (.loadingModels, .hotkeyDown):
            return (.error("Models still loading"), [.scheduleErrorClear(after: errorSeconds)])

        case (.idle, .hotkeyDown):
            return (.listening(preview: "", seconds: 0), [.startCapture, .startPreview])

        case (.listening(_, let secs), .preview(let text)):
            return (.listening(preview: text, seconds: secs), [])
        case (.listening(let p, let secs), .audio(let d)):
            let total = secs + d
            if total >= capSeconds {
                return (.finalizing(preview: p), [.stopCapture, .stopPreview, .log("cap reached"), .runFinal])
            }
            return (.listening(preview: p, seconds: total), [])
        case (.listening(let p, _), .hotkeyUp(let held)):
            if held < minHoldSeconds {
                return (.idle, [.stopCapture, .stopPreview, .log("tap ignored (<0.25s)")])
            }
            return (.finalizing(preview: p), [.stopCapture, .stopPreview, .runFinal])
        case (.listening, .cancel):
            return (.idle, [.stopCapture, .stopPreview])

        case (.finalizing(let p), .finalText(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return (.error("Nothing heard"), [.scheduleErrorClear(after: errorSeconds)]) }
            return (.finalizing(preview: p), [.insert(trimmed)])
        case (.finalizing(let p), .inserted):
            return (.shown(final: p), [.scheduleHide(after: shownSeconds)])
        case (.finalizing(let p), .insertFailed(let why)):
            return (.error(why), [.record(p), .scheduleErrorClear(after: errorSeconds)])
        case (.finalizing(let p), .engineFailed(let why)):
            return (.error("Transcription failed"), [.record(p), .log("engine: \(why)"), .scheduleErrorClear(after: errorSeconds)])
        case (.finalizing, .hotkeyDown):
            return (s, [.log("busy")])

        case (.shown, .timerFired), (.error, .timerFired):
            return (.idle, [])
        default:
            return (s, [])
        }
    }
}
```
Note: `.inserted` shows the *preview* text in the HUD (the controller substitutes the final text — see Task 9 where the controller passes the final string through `.shown`). Keep the reducer as specified; the controller maps `.shown(final:)` to the inserted string.

- [ ] **Step 4: Run tests**

Run: `swift test --filter DictationReducerTests`
Expected: 16 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAId/Core Sources/sAId/Engines/EngineProtocols.swift Sources/sAId/Support/Log.swift Tests/sAIdTests/DictationReducerTests.swift
git commit -m "feat(core): pure dictation reducer + engine protocols"
```

---

### Task 3: PostProcess — corrections, fillers, casing, protected tokens

**Files:**
- Create: `Sources/sAId/Text/Corrections.swift`, `Sources/sAId/Text/FillerRemoval.swift`, `Sources/sAId/Text/PostProcess.swift`, `Resources/default-corrections.json`, `Resources/default-fillers.json`
- Test: `Tests/sAIdTests/PostProcessTests.swift`

**Interfaces:**
- Produces:
  - `struct Correction: Codable, Equatable { var from: String; var to: String }`
  - `struct CorrectionsStore { init(fileURL: URL); func load() -> [Correction]; func save(_:) throws }`
  - `struct FillerRemoval { init(fillers: [String]); func apply(_ text: String) -> String }`
  - `struct PostProcess { init(corrections: [Correction], fillers: [String], trailingSpace: Bool = false); func apply(_ text: String) -> String }`
  - `Bundle.main` resources `default-corrections.json`, `default-fillers.json` (added to the app target in Task 10; unit tests pass arrays directly).

- [ ] **Step 1: Write the failing tests**

`Tests/sAIdTests/PostProcessTests.swift`:
```swift
import XCTest
@testable import sAId

final class PostProcessTests: XCTestCase {
    let corrections = [Correction(from: "invintus", to: "Invintus"),
                       Correction(from: "tvw", to: "TVW"),
                       Correction(from: "mimo live", to: "mimoLive")]
    let fillers = ["um", "uh", "you know"]

    func testWholeWordCaseInsensitiveCorrection() {
        let pp = PostProcess(corrections: corrections, fillers: [])
        XCTAssertEqual(pp.apply("we use Invintus and tvw daily"), "We use Invintus and TVW daily")
        XCTAssertEqual(pp.apply("the tvwmedia site"), "The tvwmedia site") // no partial match
    }

    func testMultiWordCorrection() {
        let pp = PostProcess(corrections: corrections, fillers: [])
        XCTAssertEqual(pp.apply("open mimo live now"), "Open mimoLive now")
    }

    func testFillerRemovalAndPunctuationCleanup() {
        let pp = PostProcess(corrections: [], fillers: fillers)
        XCTAssertEqual(pp.apply("um, so, uh, this is a test"), "So, this is a test")
        XCTAssertEqual(pp.apply("it is, you know, fine"), "It is fine")
    }

    func testProtectedTokensUntouched() {
        let pp = PostProcess(corrections: [Correction(from: "said", to: "SAID")], fillers: ["um"])
        XCTAssertEqual(pp.apply("see org.tvw.said and https://x.y/um"), "See org.tvw.said and https://x.y/um")
    }

    func testCapitalizesFirstLetterOnly() {
        let pp = PostProcess(corrections: [], fillers: [])
        XCTAssertEqual(pp.apply("hello there"), "Hello there")
        XCTAssertEqual(pp.apply("iPhone works"), "IPhone works".replacingOccurrences(of: "IPhone", with: "iPhone")) // leading lowercase brand kept
    }

    func testTrailingSpaceOption() {
        let pp = PostProcess(corrections: [], fillers: [], trailingSpace: true)
        XCTAssertEqual(pp.apply("done"), "Done ")
    }

    func testCorrectionsStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID()).json")
        let store = CorrectionsStore(fileURL: url)
        XCTAssertEqual(store.load(), [])
        try store.save(corrections)
        XCTAssertEqual(store.load(), corrections)
    }
}
```
(Change the `iPhone` assertion to `XCTAssertEqual(pp.apply("iPhone works"), "iPhone works")` — a word whose second character is uppercase is treated as a brand and left alone.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PostProcessTests` → compile errors (types missing).

- [ ] **Step 3: Implement**

`Sources/sAId/Text/Corrections.swift`:
```swift
import Foundation

struct Correction: Codable, Equatable, Sendable {
    var from: String
    var to: String
}

struct CorrectionsStore {
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    func load() -> [Correction] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Correction].self, from: data) else { return [] }
        return list
    }

    func save(_ corrections: [Correction]) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(corrections).write(to: fileURL, options: .atomic)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sAId/corrections.json")
    }
}
```

`Sources/sAId/Text/FillerRemoval.swift`:
```swift
import Foundation

struct FillerRemoval {
    let fillers: [String]
    init(fillers: [String]) { self.fillers = fillers.sorted { $0.count > $1.count } }

    func apply(_ text: String) -> String {
        var out = text
        for f in fillers {
            // filler as a whole word, optionally followed by a comma; keeps surrounding words
            let pattern = "(?i)(^|\\s|,\\s*)" + NSRegularExpression.escapedPattern(for: f) + "(,?)(?=\\s|$|,)"
            out = out.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s*,\\s*,", with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: "^[\\s,]+", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}
```

`Sources/sAId/Text/PostProcess.swift`:
```swift
import Foundation

struct PostProcess {
    let corrections: [Correction]
    let fillers: FillerRemoval
    let trailingSpace: Bool

    init(corrections: [Correction], fillers: [String], trailingSpace: Bool = false) {
        self.corrections = corrections.sorted { $0.from.count > $1.from.count }
        self.fillers = FillerRemoval(fillers: fillers)
        self.trailingSpace = trailingSpace
    }

    /// A token containing `/`, `_`, `@`, or a `.` between letters is a URL/identifier: never touched.
    static func isProtected(_ token: String) -> Bool {
        if token.contains("/") || token.contains("_") || token.contains("@") { return true }
        return token.range(of: "[A-Za-z]\\.[A-Za-z]", options: .regularExpression) != nil
    }

    func apply(_ text: String) -> String {
        var out = applyCorrections(text)
        out = fillers.apply(out)
        out = capitalizeFirst(out)
        return trailingSpace && !out.isEmpty ? out + " " : out
    }

    private func applyCorrections(_ text: String) -> String {
        // Split on whitespace, protect URL-like tokens, then run multi-word corrections on the rest.
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var protectedMap: [String: String] = [:]
        var masked: [String] = []
        for (i, t) in tokens.enumerated() {
            if Self.isProtected(t) { let key = "\u{E000}\(i)\u{E001}"; protectedMap[key] = t; masked.append(key) }
            else { masked.append(t) }
        }
        var joined = masked.joined(separator: " ")
        for c in corrections {
            let pattern = "(?i)(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: c.from) + "(?![A-Za-z0-9])"
            joined = joined.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: c.to), options: .regularExpression)
        }
        for (key, original) in protectedMap { joined = joined.replacingOccurrences(of: key, with: original) }
        return joined
    }

    private func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first, first.isLetter, first.isLowercase else { return s }
        let second = s.dropFirst().first
        if let second, second.isUppercase { return s }   // iPhone, mimoLive
        return first.uppercased() + s.dropFirst()
    }
}
```

`Resources/default-corrections.json`:
```json
[
  {"from": "invintus", "to": "Invintus"},
  {"from": "tvw", "to": "TVW"},
  {"from": "mimo live", "to": "mimoLive"},
  {"from": "live bus", "to": "LAIveBus"},
  {"from": "ndi", "to": "NDI"}
]
```
`Resources/default-fillers.json`:
```json
["um", "uh", "er", "hmm", "you know", "like,"]
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PostProcessTests` → all pass. If `testFillerRemovalAndPunctuationCleanup` fails on the exact comma placement, adjust the regex cleanup lines — the required outputs are the assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAId/Text Resources Tests/sAIdTests/PostProcessTests.swift
git commit -m "feat(text): corrections dictionary, filler removal, casing, protected tokens"
```

---

### Task 4: AudioCapture — AVAudioEngine tap → 16 kHz mono chunks

**Files:**
- Create: `Sources/sAId/Audio/ConverterFeeder.swift`, `Sources/sAId/Audio/AudioCapture.swift`
- Test: `Tests/sAIdTests/ConverterFeederTests.swift`

**Interfaces:**
- Produces:
  - `final class ConverterFeeder { init(); func enqueue(_ buffer: AVAudioPCMBuffer); var inputBlock: AVAudioConverterInputBlock { get } }` — the block returns the queued buffer with `.haveData`, else `.noDataNow`. **Never `.endOfStream`.**
  - `final class AudioCapture: @unchecked Sendable { init(deviceUID: String? = nil); func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws; func stop() }` — chunks are 16 kHz mono, ~64 ms (1024 frames).
  - `static func floats(from buffer: AVAudioPCMBuffer) -> [Float]`

- [ ] **Step 1: Write the failing test (the invariant)**

`Tests/sAIdTests/ConverterFeederTests.swift`:
```swift
import XCTest
import AVFoundation
@testable import sAId

final class ConverterFeederTests: XCTestCase {
    func testEmptyQueueReturnsNoDataNowNeverEndOfStream() {
        let feeder = ConverterFeeder()
        var status = AVAudioConverterInputStatus.endOfStream
        let out = feeder.inputBlock(1024, &status)
        XCTAssertNil(out)
        XCTAssertEqual(status, .noDataNow)
    }

    func testQueuedBufferIsReturnedOnceWithHaveData() {
        let feeder = ConverterFeeder()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!; buf.frameLength = 480
        feeder.enqueue(buf)
        var status = AVAudioConverterInputStatus.noDataNow
        XCTAssertNotNil(feeder.inputBlock(480, &status)); XCTAssertEqual(status, .haveData)
        XCTAssertNil(feeder.inputBlock(480, &status)); XCTAssertEqual(status, .noDataNow)
    }

    func testFloatsExtraction() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4)!; buf.frameLength = 4
        buf.floatChannelData![0][0] = 0.5; buf.floatChannelData![0][3] = -0.25
        XCTAssertEqual(AudioCapture.floats(from: buf), [0.5, 0, 0, -0.25])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ConverterFeederTests` → compile errors.

- [ ] **Step 3: Implement**

`Sources/sAId/Audio/ConverterFeeder.swift`:
```swift
import AVFoundation

/// Feeds AVAudioConverter one input buffer at a time.
/// INVARIANT (spec §2.3): with no buffer queued, report `.noDataNow` — NEVER `.endOfStream`,
/// which puts the converter into a terminal state so every later press captures silence.
final class ConverterFeeder {
    private var pending: AVAudioPCMBuffer?
    private let lock = NSLock()

    func enqueue(_ buffer: AVAudioPCMBuffer) { lock.lock(); pending = buffer; lock.unlock() }

    var inputBlock: AVAudioConverterInputBlock {
        { [unowned self] _, status in
            self.lock.lock(); defer { self.lock.unlock() }
            if let b = self.pending { self.pending = nil; status.pointee = .haveData; return b }
            status.pointee = .noDataNow
            return nil
        }
    }
}
```

`Sources/sAId/Audio/AudioCapture.swift`:
```swift
import AVFoundation
import os

/// Owns AVAudioEngine. NOT @MainActor: the tap fires on an audio thread (spec §2.3).
/// Converts the hardware format to 16 kHz mono Float32 and hands ~64 ms chunks to `onChunk`
/// on a private serial queue. Never transcribes inline.
final class AudioCapture: @unchecked Sendable {
    static let targetRate = 16_000.0
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "org.tvw.said.audio", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private let feeder = ConverterFeeder()
    private let deviceUID: String?

    init(deviceUID: String? = nil) { self.deviceUID = deviceUID }

    static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
    }

    func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        if let uid = deviceUID { try Self.select(inputDeviceUID: uid, on: input) }
        let hw = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: hw, to: target) else { throw CaptureError.formatUnavailable }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buffer, _ in
            guard let self, let conv = self.converter else { return }
            let ratio = Self.targetRate / hw.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return }
            self.feeder.enqueue(buffer)
            var err: NSError?
            let status = conv.convert(to: out, error: &err, withInputFrom: self.feeder.inputBlock)
            if status == .error { Log.audio.error("convert: \(err?.localizedDescription ?? "?")"); return }
            let samples = Self.floats(from: out)
            if !samples.isEmpty { self.queue.async { onChunk(samples) } }
        }
        engine.prepare()
        try engine.start()
        Log.audio.info("capture started \(hw.sampleRate) Hz → 16 kHz")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        Log.audio.info("capture stopped")
    }

    enum CaptureError: Error { case formatUnavailable, deviceNotFound }

    private static func select(inputDeviceUID uid: String, on node: AVAudioInputNode) throws {
        // CoreAudio device selection by UID
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), ptr, &size, &deviceID)
        }
        guard status == noErr, deviceID != 0 else { throw CaptureError.deviceNotFound }
        var id = deviceID
        let unit = node.audioUnit!
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter ConverterFeederTests` → 3 pass. `swift build` green.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAId/Audio Tests/sAIdTests/ConverterFeederTests.swift
git commit -m "feat(audio): AVAudioEngine capture to 16 kHz mono with .noDataNow converter feeder"
```

---

### Task 5: Hotkey — decider (pure) + CGEventTap listener (ported)

**Files:**
- Create: `Sources/sAId/Hotkey/HotkeyDecider.swift`, `Sources/sAId/Hotkey/HotkeyListener.swift`
- Reference: `docs/borrowed/parakey-hotkey-listener.swift`
- Test: `Tests/sAIdTests/HotkeyDeciderTests.swift`

**Interfaces:**
- Produces:
  - `enum HotkeyAction: Equatable { case pressed, released(heldSeconds: Double), cancel, none }`
  - `struct HotkeyDecider { init(keycode: Int64); mutating func decide(type: CGEventType, keycode: Int64, flags: CGEventFlags, isAutoRepeat: Bool, now: Double) -> HotkeyAction }` — for modifier keycodes (54, 55, 56, 58, 59, 60, 61, 62, 63) it watches `.flagsChanged` and diffs the relevant flag; for ordinary keys it uses keyDown/keyUp; Esc (53) while held → `.cancel`.
  - `final class HotkeyListener { init(keycode: Int64, onAction: @escaping @Sendable (HotkeyAction) -> Void); func start() throws; func stop() }` — installs a session event tap, re-enables on `tapDisabledByTimeout`.

- [ ] **Step 1: Write the failing tests**

`Tests/sAIdTests/HotkeyDeciderTests.swift`:
```swift
import XCTest
import CoreGraphics
@testable import sAId

final class HotkeyDeciderTests: XCTestCase {
    func testRightOptionPressReleaseViaFlagsChanged() {
        var d = HotkeyDecider(keycode: 61)
        XCTAssertEqual(d.decide(type: .flagsChanged, keycode: 61, flags: [.maskAlternate], isAutoRepeat: false, now: 10.0), .pressed)
        XCTAssertEqual(d.decide(type: .flagsChanged, keycode: 61, flags: [], isAutoRepeat: false, now: 11.5), .released(heldSeconds: 1.5))
    }

    func testLeftOptionDoesNotTriggerRightOptionHotkey() {
        var d = HotkeyDecider(keycode: 61)
        XCTAssertEqual(d.decide(type: .flagsChanged, keycode: 58, flags: [.maskAlternate], isAutoRepeat: false, now: 1), .none)
    }

    func testEscapeWhileHeldCancelsAndReleaseIsThenIgnored() {
        var d = HotkeyDecider(keycode: 61)
        _ = d.decide(type: .flagsChanged, keycode: 61, flags: [.maskAlternate], isAutoRepeat: false, now: 1)
        XCTAssertEqual(d.decide(type: .keyDown, keycode: 53, flags: [.maskAlternate], isAutoRepeat: false, now: 2), .cancel)
        XCTAssertEqual(d.decide(type: .flagsChanged, keycode: 61, flags: [], isAutoRepeat: false, now: 3), .none)
    }

    func testOrdinaryKeyUsesKeyDownUpAndIgnoresAutoRepeat() {
        var d = HotkeyDecider(keycode: 78) // keypad minus
        XCTAssertEqual(d.decide(type: .keyDown, keycode: 78, flags: [], isAutoRepeat: false, now: 0), .pressed)
        XCTAssertEqual(d.decide(type: .keyDown, keycode: 78, flags: [], isAutoRepeat: true, now: 0.3), .none)
        XCTAssertEqual(d.decide(type: .keyUp, keycode: 78, flags: [], isAutoRepeat: false, now: 2), .released(heldSeconds: 2))
    }

    func testEscapeWhenNotHeldIsNone() {
        var d = HotkeyDecider(keycode: 61)
        XCTAssertEqual(d.decide(type: .keyDown, keycode: 53, flags: [], isAutoRepeat: false, now: 1), .none)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter HotkeyDeciderTests` → compile errors.

- [ ] **Step 3: Implement the decider**

`Sources/sAId/Hotkey/HotkeyDecider.swift`:
```swift
import CoreGraphics

enum HotkeyAction: Equatable { case pressed, released(heldSeconds: Double), cancel, none }

/// Pure press/release/cancel logic. Modifier keys (Option/Command/Shift/Control/Fn) never emit
/// keyDown; they arrive as `.flagsChanged`, so we diff the matching flag and require the physical
/// keycode to match (Right Option = 61, Left Option = 58) — flag masks are side-agnostic.
struct HotkeyDecider {
    static let escape: Int64 = 53
    let keycode: Int64
    private var held = false
    private var cancelled = false
    private var pressedAt: Double = 0

    init(keycode: Int64) { self.keycode = keycode }

    private static func modifierFlag(for keycode: Int64) -> CGEventFlags? {
        switch keycode {
        case 58, 61: return .maskAlternate
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 63:     return .maskSecondaryFn
        default:     return nil
        }
    }

    mutating func decide(type: CGEventType, keycode kc: Int64, flags: CGEventFlags, isAutoRepeat: Bool, now: Double) -> HotkeyAction {
        if held, type == .keyDown, kc == Self.escape { held = false; cancelled = true; return .cancel }
        guard kc == keycode else { return .none }
        if let flag = Self.modifierFlag(for: keycode) {
            guard type == .flagsChanged else { return .none }
            let down = flags.contains(flag)
            return transition(down: down, now: now)
        }
        switch type {
        case .keyDown where !isAutoRepeat: return transition(down: true, now: now)
        case .keyUp: return transition(down: false, now: now)
        default: return .none
        }
    }

    private mutating func transition(down: Bool, now: Double) -> HotkeyAction {
        if down {
            if held { return .none }
            held = true; cancelled = false; pressedAt = now
            return .pressed
        } else {
            if cancelled { cancelled = false; return .none }
            guard held else { return .none }
            held = false
            return .released(heldSeconds: now - pressedAt)
        }
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter HotkeyDeciderTests` → 5 pass.

- [ ] **Step 5: Port the listener**

Create `Sources/sAId/Hotkey/HotkeyListener.swift`, starting with the MIT notice line from `docs/borrowed/parakey-hotkey-listener.swift`, then:
```swift
// Adapted from Parakey (MIT, © 2026 Richard Courtman) — https://github.com/rcourtman/parakey
import CoreGraphics
import Foundation
import os

final class HotkeyListener: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var decider: HotkeyDecider
    private let onAction: @Sendable (HotkeyAction) -> Void
    private let lock = NSLock()

    init(keycode: Int64, onAction: @escaping @Sendable (HotkeyAction) -> Void) {
        self.decider = HotkeyDecider(keycode: keycode)
        self.onAction = onAction
    }

    enum ListenerError: Error { case tapCreationFailed }

    func start() throws {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: ref) else { throw ListenerError.tapCreationFailed }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotkey.info("event tap installed")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true); Log.hotkey.notice("tap re-enabled") }
            return
        }
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        let repeatFlag = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        lock.lock()
        let action = decider.decide(type: type, keycode: kc, flags: event.flags, isAutoRepeat: repeatFlag, now: Date().timeIntervalSinceReferenceDate)
        lock.unlock()
        if action != .none { onAction(action) }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
}
```
Note: `.listenOnly` — sAId never swallows the key; Right-Option keeps working for other apps.

- [ ] **Step 6: Build and commit**

Run: `swift build && swift test`
```bash
git add Sources/sAId/Hotkey Tests/sAIdTests/HotkeyDeciderTests.swift
git commit -m "feat(hotkey): pure decider + CGEventTap listener (ported from Parakey, MIT)"
```

---

### Task 6: TextInserter — pasteboard snapshot, ⌘V, restore, secure-input guard (ported)

**Files:**
- Create: `Sources/sAId/Insert/PasteboardSnapshot.swift`, `Sources/sAId/Insert/TextInserter.swift`
- Reference: `docs/borrowed/parakey-text-insertion.swift`
- Test: `Tests/sAIdTests/PasteboardSnapshotTests.swift`

**Interfaces:**
- Produces:
  - `struct PasteboardSnapshot: Equatable { let items: [[String: Data]]; static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot; func restore(to pb: NSPasteboard) }`
  - `enum InsertError: Error, Equatable { case secureInput, pasteFailed }`
  - `final class TextInserter: Sendable { init(); func insert(_ text: String) async throws }` — throws `.secureInput` if `IsSecureEventInputEnabled()`; writes, posts ⌘V, waits 150 ms, restores; on paste failure leaves the text on the clipboard and throws `.pasteFailed`.

- [ ] **Step 1: Write the failing tests**

`Tests/sAIdTests/PasteboardSnapshotTests.swift`:
```swift
import XCTest
import AppKit
@testable import sAId

final class PasteboardSnapshotTests: XCTestCase {
    func testCaptureAndRestoreRoundTrip() {
        let pb = NSPasteboard(name: NSPasteboard.Name("org.tvw.said.test-\(UUID())"))
        pb.clearContents(); pb.setString("SENTINEL-42", forType: .string)
        let snap = PasteboardSnapshot.capture(pb)
        pb.clearContents(); pb.setString("dictated text", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "dictated text")
        snap.restore(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "SENTINEL-42")
    }

    func testEmptyPasteboardRestoresToEmpty() {
        let pb = NSPasteboard(name: NSPasteboard.Name("org.tvw.said.test-\(UUID())"))
        pb.clearContents()
        let snap = PasteboardSnapshot.capture(pb)
        pb.setString("x", forType: .string)
        snap.restore(to: pb)
        XCTAssertNil(pb.string(forType: .string))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter PasteboardSnapshotTests` → compile errors.

- [ ] **Step 3: Implement**

`Sources/sAId/Insert/PasteboardSnapshot.swift`:
```swift
import AppKit

struct PasteboardSnapshot: Equatable {
    let items: [[String: Data]]

    static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let items = (pb.pasteboardItems ?? []).map { item -> [String: Data] in
            var d: [String: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t.rawValue] = data } }
            return d
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(t)) }
            return item
        }
        pb.writeObjects(restored)
    }
}
```

`Sources/sAId/Insert/TextInserter.swift` (first line: the MIT notice from `docs/borrowed/parakey-text-insertion.swift`):
```swift
// Adapted from Parakey (MIT, © 2026 Richard Courtman) — https://github.com/rcourtman/parakey
import AppKit
import Carbon.HIToolbox
import os

enum InsertError: Error, Equatable { case secureInput, pasteFailed }

final class TextInserter: Sendable {
    static let restoreDelayMs: UInt64 = 150

    func insert(_ text: String) async throws {
        if IsSecureEventInputEnabled() { throw InsertError.secureInput }
        let pb = NSPasteboard.general
        let snapshot = await MainActor.run { PasteboardSnapshot.capture(pb) }
        let wrote = await MainActor.run { pb.clearContents(); return pb.setString(text, forType: .string) }
        guard wrote else { throw InsertError.pasteFailed }
        guard Self.postCommandV() else {
            Log.insert.error("⌘V post failed; text left on clipboard")
            throw InsertError.pasteFailed
        }
        try await Task.sleep(nanoseconds: Self.restoreDelayMs * 1_000_000)
        await MainActor.run { snapshot.restore(to: pb) }
        Log.insert.info("inserted \(text.count) chars; clipboard restored")
    }

    private static func postCommandV() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter PasteboardSnapshotTests` → 2 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAId/Insert Tests/sAIdTests/PasteboardSnapshotTests.swift
git commit -m "feat(insert): pasteboard snapshot/restore + ⌘V paste with secure-input guard (ported from Parakey, MIT)"
```

---

### Task 7: MoonshinePreviewEngine adapter

**Files:**
- Create: `Sources/sAId/Engines/MoonshinePreviewEngine.swift`
- Test: `Tests/sAIdTests/MoonshinePreviewEngineTests.swift` (contract test, skips without a model)

**Interfaces:**
- Consumes: `PreviewTranscriber`, `PreviewLine` (Task 2). Third-party: `MoonshineVoice.AssetDownloader().ensureModelPresent(root:spec:onProgress:) async throws -> URL`, `ModelSpec.stt(language:modelArch:includeSpelling:includeWordTimestamps:)`, `Transcriber(modelPath:modelArch:options:spellingModelPath:) throws`, `transcriber.createStream(updateInterval:flags:transcribeFlags:) throws -> Stream`, `transcriber.setKeyterms([String]) throws`, `Stream.start()/stop()/close()`, `Stream.addAudio(_:sampleRate:) throws`, `Stream.addListener((TranscriptEvent) throws -> Void)`, events `LineTextChanged`/`LineCompleted` (`.line.text`), `TranscriptError` (`.error`).
- Produces: `final class MoonshinePreviewEngine: PreviewTranscriber { init(modelRoot: URL); func load(keyterms: [String], progress: (@Sendable (Double) -> Void)?) async throws; static var defaultModelRoot: URL }`

- [ ] **Step 1: Write the failing contract test**

`Tests/sAIdTests/MoonshinePreviewEngineTests.swift`:
```swift
import XCTest
@testable import sAId

final class MoonshinePreviewEngineTests: XCTestCase {
    func testStreamsPartialLinesForSyntheticTone() async throws {
        let root = MoonshinePreviewEngine.defaultModelRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "Moonshine model not cached; run the app once")
        let engine = MoonshinePreviewEngine(modelRoot: root)
        try await engine.load(keyterms: [], progress: nil)
        try engine.start()
        // 1 s of silence then a 440 Hz tone: we only assert the pipeline emits without throwing.
        let silence = [Float](repeating: 0, count: 16_000)
        engine.feed(silence)
        engine.stop()
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 2: Run** — `swift test --filter MoonshinePreviewEngineTests` → compile error (type missing).

- [ ] **Step 3: Implement**

`Sources/sAId/Engines/MoonshinePreviewEngine.swift`:
```swift
import Foundation
import MoonshineVoice
import os

/// Wraps Moonshine's streaming Transcriber/Stream. The app's AudioCapture owns the microphone;
/// we only feed 16 kHz chunks in. Live text is preview-only and is never pasted.
final class MoonshinePreviewEngine: PreviewTranscriber, @unchecked Sendable {
    static var defaultModelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sAId/models/moonshine", isDirectory: true)
    }

    private let modelRoot: URL
    private var transcriber: Transcriber?
    private var stream: Stream?
    private let continuation: AsyncStream<PreviewLine>.Continuation
    let lines: AsyncStream<PreviewLine>

    init(modelRoot: URL) {
        self.modelRoot = modelRoot
        var c: AsyncStream<PreviewLine>.Continuation!
        lines = AsyncStream { c = $0 }
        continuation = c
    }

    func load(keyterms: [String], progress: (@Sendable (Double) -> Void)?) async throws {
        let downloader = AssetDownloader()
        let path = try await downloader.ensureModelPresent(
            root: modelRoot,
            spec: .stt(language: "en", modelArch: .mediumStreaming),
            onProgress: { p in progress?(Double(p.bytesReceived) / Double(max(p.bytesExpected, 1))) })
        let t = try Transcriber(modelPath: path.path, modelArch: .mediumStreaming)
        if !keyterms.isEmpty { try t.setKeyterms(keyterms.filter { !$0.contains(",") }) }
        let s = try t.createStream(updateInterval: 0.3)
        s.addListener { [continuation] event in
            switch event {
            case let e as LineTextChanged: continuation.yield(PreviewLine(text: e.line.text, isFinal: false))
            case let e as LineCompleted:   continuation.yield(PreviewLine(text: e.line.text, isFinal: true))
            case let e as TranscriptError: Log.engine.error("moonshine: \(String(describing: e.error))")
            default: break
            }
        }
        transcriber = t; stream = s
        Log.engine.info("moonshine mediumStreaming ready at \(path.path)")
    }

    func start() throws { try stream?.start() }
    func feed(_ pcm16k: [Float]) { try? stream?.addAudio(pcm16k, sampleRate: 16000) }
    func stop() { try? stream?.stop() }
    deinit { stream?.close(); transcriber?.close(); continuation.finish() }
}
```
If `DownloadProgress` field names differ from `bytesReceived`/`bytesExpected`, open `.build/checkouts/moonshine-swift/Sources/MoonshineVoice/Progress.swift` and use its actual property names — the two-field ratio is all we need.

- [ ] **Step 4: Build; run the test (it skips until a model is cached)**

Run: `swift build && swift test --filter MoonshinePreviewEngineTests` → builds; test reports skipped.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAId/Engines/MoonshinePreviewEngine.swift Tests/sAIdTests/MoonshinePreviewEngineTests.swift
git commit -m "feat(engine): Moonshine mediumStreaming preview adapter with keyterms"
```

---

### Task 8: Qwen3FinalEngine adapter

**Files:**
- Create: `Sources/sAId/Engines/Qwen3FinalEngine.swift`
- Test: `Tests/sAIdTests/Qwen3FinalEngineTests.swift` (contract test, skips without cached weights)

**Interfaces:**
- Consumes: `FinalTranscriber` (Task 2). Third-party (`Qwen3ASR`): `Qwen3ASRModel.fromPretrained(modelId:cacheDir:offlineMode:progressHandler:) async throws -> Qwen3ASRModel`; `Qwen3DecodingOptions()` with `maxTokens`, `language`, `context`; `model.transcribeCheckingCancellation(audio:sampleRate:options:) throws -> String`.
- Produces: `final class Qwen3FinalEngine: FinalTranscriber { static let modelId = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"; init(); func load(progress: (@Sendable (Double, String) -> Void)?) async throws; func transcribe(_ pcm16k: [Float]) async throws -> String }`

- [ ] **Step 1: Write the failing contract test**

`Tests/sAIdTests/Qwen3FinalEngineTests.swift`:
```swift
import XCTest
@testable import sAId

final class Qwen3FinalEngineTests: XCTestCase {
    func testTranscribesSilenceToEmptyOrShortString() async throws {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("qwen3-speech")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cache.path), "Qwen3 weights not cached; run the app once")
        let engine = Qwen3FinalEngine()
        try await engine.load(progress: nil)
        let text = try await engine.transcribe([Float](repeating: 0, count: 16_000))
        XCTAssertLessThan(text.count, 40)
    }
}
```

- [ ] **Step 2: Run** — compile error (type missing).

- [ ] **Step 3: Implement**

`Sources/sAId/Engines/Qwen3FinalEngine.swift`:
```swift
import Foundation
import Qwen3ASR
import os

/// Whole-utterance transcription with Qwen3-ASR 1.7B (MLX 8-bit). Loads once; stays resident.
final class Qwen3FinalEngine: FinalTranscriber, @unchecked Sendable {
    static let modelId = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    private var model: Qwen3ASRModel?
    private let work = DispatchQueue(label: "org.tvw.said.qwen3", qos: .userInitiated)

    func load(progress: (@Sendable (Double, String) -> Void)?) async throws {
        do {
            model = try await Qwen3ASRModel.fromPretrained(modelId: Self.modelId, offlineMode: true, progressHandler: progress)
        } catch {
            Log.engine.notice("qwen3 offline load failed (\(String(describing: error))); downloading")
            model = try await Qwen3ASRModel.fromPretrained(modelId: Self.modelId, offlineMode: false, progressHandler: progress)
        }
        Log.engine.info("qwen3 \(Self.modelId) ready")
    }

    func transcribe(_ pcm16k: [Float]) async throws -> String {
        guard let model else { throw EngineError.notLoaded }
        return try await withCheckedThrowingContinuation { cont in
            work.async {
                var opts = Qwen3DecodingOptions()
                opts.language = "en"
                do { cont.resume(returning: try model.transcribeCheckingCancellation(audio: pcm16k, sampleRate: 16000, options: opts)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    enum EngineError: Error { case notLoaded }
}
```

- [ ] **Step 4: Build; test skips** — `swift build && swift test --filter Qwen3FinalEngineTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/sAId/Engines/Qwen3FinalEngine.swift Tests/sAIdTests/Qwen3FinalEngineTests.swift
git commit -m "feat(engine): Qwen3-ASR 1.7B final-transcription adapter"
```

---

### Task 9: DictationController (effects executor) + HUD

**Files:**
- Create: `Sources/sAId/Core/DictationController.swift`, `Sources/sAId/UI/HUDPanel.swift`, `Sources/sAId/UI/HUDView.swift`
- Test: `Tests/sAIdTests/DictationControllerTests.swift` (with fakes), `Tests/sAIdTests/Fakes.swift`

**Interfaces:**
- Consumes: reducer/state/effects (Task 2), `PostProcess` (Task 3), `AudioCapture` (Task 4), `TextInserter` (Task 6), engines (7, 8).
- Produces:
  - `protocol CaptureSource: AnyObject, Sendable { func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws; func stop() }` (extend `AudioCapture` to conform).
  - `protocol TextSink: Sendable { func insert(_ text: String) async throws }` (extend `TextInserter`).
  - `actor DictationController { init(capture: CaptureSource, preview: PreviewTranscriber, final: FinalTranscriber, sink: TextSink, post: PostProcess, history: @escaping @Sendable (String) -> Void); var states: AsyncStream<DictationState> { get }; func modelsReady(); func hotkey(_ a: HotkeyAction); func send(_ e: DictationEvent) }`
  - `@MainActor final class HUDPanel: NSPanel { init(); func show(state: DictationState); }` and `struct HUDView: View { let state: DictationState }`.

- [ ] **Step 1: Write the fakes and the failing controller tests**

`Tests/sAIdTests/Fakes.swift`:
```swift
import Foundation
@testable import sAId

final class FakeCapture: CaptureSource, @unchecked Sendable {
    var onChunk: (@Sendable ([Float]) -> Void)?
    private(set) var started = 0, stopped = 0
    func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws { started += 1; self.onChunk = onChunk }
    func stop() { stopped += 1 }
    func emit(seconds: Double) { onChunk?([Float](repeating: 0.1, count: Int(16_000 * seconds))) }
}

final class FakePreview: PreviewTranscriber, @unchecked Sendable {
    private let c: AsyncStream<PreviewLine>.Continuation
    let lines: AsyncStream<PreviewLine>
    private(set) var fed = 0, started = 0, stopped = 0
    init() { var cc: AsyncStream<PreviewLine>.Continuation!; lines = AsyncStream { cc = $0 }; c = cc }
    func start() throws { started += 1 }
    func feed(_ pcm16k: [Float]) { fed += 1 }
    func stop() { stopped += 1 }
    func push(_ text: String) { c.yield(PreviewLine(text: text, isFinal: false)) }
}

struct FakeFinal: FinalTranscriber {
    let result: Result<String, Error>
    func transcribe(_ pcm16k: [Float]) async throws -> String { try result.get() }
}

final class FakeSink: TextSink, @unchecked Sendable {
    private(set) var inserted: [String] = []
    var failWith: InsertError?
    func insert(_ text: String) async throws { if let e = failWith { throw e }; inserted.append(text) }
}
```

`Tests/sAIdTests/DictationControllerTests.swift`:
```swift
import XCTest
@testable import sAId

final class DictationControllerTests: XCTestCase {
    func testHoldSpeakReleaseInsertsPostProcessedText() async throws {
        let cap = FakeCapture(), prev = FakePreview(), sink = FakeSink()
        let post = PostProcess(corrections: [Correction(from: "tvw", to: "TVW")], fillers: ["um"])
        var recorded: [String] = []
        let ctl = DictationController(capture: cap, preview: prev, final: FakeFinal(result: .success("um hello tvw")),
                                      sink: sink, post: post, history: { recorded.append($0) })
        await ctl.modelsReady()
        await ctl.hotkey(.pressed)
        cap.emit(seconds: 1.0)
        prev.push("hello")
        try await Task.sleep(nanoseconds: 50_000_000)
        await ctl.hotkey(.released(heldSeconds: 1.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sink.inserted, ["Hello TVW"])
        XCTAssertEqual(cap.started, 1); XCTAssertEqual(cap.stopped, 1)
        XCTAssertEqual(prev.started, 1); XCTAssertEqual(prev.stopped, 1)
        XCTAssertEqual(recorded, ["Hello TVW"])
    }

    func testSecureInputFailureRecordsPreviewAndInsertsNothing() async throws {
        let cap = FakeCapture(), prev = FakePreview(), sink = FakeSink(); sink.failWith = .secureInput
        var recorded: [String] = []
        let ctl = DictationController(capture: cap, preview: prev, final: FakeFinal(result: .success("secret")),
                                      sink: sink, post: PostProcess(corrections: [], fillers: []), history: { recorded.append($0) })
        await ctl.modelsReady()
        await ctl.hotkey(.pressed); cap.emit(seconds: 1)
        await ctl.hotkey(.released(heldSeconds: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sink.inserted, [])
        XCTAssertEqual(recorded, ["Secret"])
        let state = await ctl.currentState
        XCTAssertEqual(state, .error("Secure input field"))
    }

    func testTapIsIgnored() async throws {
        let cap = FakeCapture(), prev = FakePreview(), sink = FakeSink()
        let ctl = DictationController(capture: cap, preview: prev, final: FakeFinal(result: .success("x")),
                                      sink: sink, post: PostProcess(corrections: [], fillers: []), history: { _ in })
        await ctl.modelsReady()
        await ctl.hotkey(.pressed)
        await ctl.hotkey(.released(heldSeconds: 0.1))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sink.inserted, [])
        XCTAssertEqual(await ctl.currentState, .idle)
    }
}
```

- [ ] **Step 2: Run** — compile errors.

- [ ] **Step 3: Implement the controller**

Add to `Sources/sAId/Audio/AudioCapture.swift`: `protocol CaptureSource: AnyObject, Sendable { func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws; func stop() }` and `extension AudioCapture: CaptureSource {}`.
Add to `Sources/sAId/Insert/TextInserter.swift`: `protocol TextSink: Sendable { func insert(_ text: String) async throws }` and `extension TextInserter: TextSink {}`.

`Sources/sAId/Core/DictationController.swift`:
```swift
import Foundation
import os

actor DictationController {
    private(set) var currentState: DictationState = .loadingModels
    private let capture: CaptureSource
    private let preview: PreviewTranscriber
    private let final: FinalTranscriber
    private let sink: TextSink
    private let post: PostProcess
    private let history: @Sendable (String) -> Void
    private var buffer: [Float] = []
    private var lastFinal = ""
    private var timer: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let stateContinuation: AsyncStream<DictationState>.Continuation
    nonisolated let states: AsyncStream<DictationState>

    init(capture: CaptureSource, preview: PreviewTranscriber, final: FinalTranscriber,
         sink: TextSink, post: PostProcess, history: @escaping @Sendable (String) -> Void) {
        self.capture = capture; self.preview = preview; self.final = final
        self.sink = sink; self.post = post; self.history = history
        var c: AsyncStream<DictationState>.Continuation!
        states = AsyncStream { c = $0 }; stateContinuation = c
    }

    func modelsReady() { send(.modelsReady) }
    func modelsFailed(_ why: String) { send(.modelsFailed(why)) }

    func hotkey(_ a: HotkeyAction) {
        switch a {
        case .pressed: send(.hotkeyDown)
        case .released(let held): send(.hotkeyUp(heldSeconds: held))
        case .cancel: send(.cancel)
        case .none: break
        }
    }

    func send(_ e: DictationEvent) {
        let (next, effects) = DictationReducer.reduce(currentState, e)
        // The HUD shows the pasted text, not the preview, once inserted.
        if case .shown = next, !lastFinal.isEmpty { currentState = .shown(final: lastFinal) } else { currentState = next }
        stateContinuation.yield(currentState)
        for fx in effects { run(fx) }
    }

    private func run(_ fx: DictationEffect) {
        switch fx {
        case .startCapture:
            buffer.removeAll(keepingCapacity: true)
            do {
                try capture.start { [weak self] chunk in Task { await self?.ingest(chunk) } }
            } catch { send(.engineFailed("capture: \(error)")) }
        case .stopCapture: capture.stop()
        case .startPreview:
            do { try preview.start() } catch { Log.engine.error("preview start: \(String(describing: error))") }
            previewTask?.cancel()
            previewTask = Task { [weak self] in
                guard let self else { return }
                for await line in self.preview.lines { await self.send(.preview(line.text)) }
            }
        case .stopPreview: preview.stop(); previewTask?.cancel(); previewTask = nil
        case .runFinal:
            let pcm = buffer
            Task { [weak self] in
                guard let self else { return }
                do { let raw = try await self.final.transcribe(pcm); await self.send(.finalText(raw)) }
                catch { await self.send(.engineFailed(String(describing: error))) }
            }
        case .insert(let raw):
            let text = post.apply(raw)
            lastFinal = text
            Task { [weak self] in
                guard let self else { return }
                do { try await self.sink.insert(text); self.history(text); await self.send(.inserted) }
                catch InsertError.secureInput { await self.send(.insertFailed("Secure input field")) }
                catch { await self.send(.insertFailed("Paste failed — text copied to clipboard")) }
            }
        case .scheduleHide(let after), .scheduleErrorClear(let after):
            timer?.cancel()
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.send(.timerFired)
            }
        case .record(let previewText):
            let text = post.apply(previewText)
            if !text.isEmpty { history(text) }
        case .log(let msg): Log.app.info("\(msg)")
        }
    }

    private func ingest(_ chunk: [Float]) {
        guard case .listening = currentState else { return }
        buffer.append(contentsOf: chunk)
        preview.feed(chunk)
        send(.audio(seconds: Double(chunk.count) / 16_000))
    }
}
```

- [ ] **Step 4: Run controller tests** — `swift test --filter DictationControllerTests` → 3 pass. (If `testSecureInputFailure…` records `"Secret"` vs `"secret"`: `.record` runs `post.apply`, which capitalizes — the assertion expects `"Secret"`.)

- [ ] **Step 5: HUD panel and view**

`Sources/sAId/UI/HUDView.swift`:
```swift
import SwiftUI

struct HUDView: View {
    let state: DictationState

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(label).lineLimit(1).truncationMode(.head).font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: 560)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .listening: Image(systemName: "mic.fill").foregroundStyle(.red)
        case .finalizing: ProgressView().controlSize(.small)
        case .shown: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .loadingModels: ProgressView().controlSize(.small)
        case .idle: EmptyView()
        }
    }

    private var label: String {
        switch state {
        case .listening(let p, _): return p.isEmpty ? "Listening…" : p
        case .finalizing(let p): return p.isEmpty ? "Finalizing…" : p
        case .shown(let f): return f
        case .error(let e): return e
        case .loadingModels: return "Loading models…"
        case .idle: return ""
        }
    }
}
```

`Sources/sAId/UI/HUDPanel.swift`:
```swift
import AppKit
import SwiftUI

/// Floating, non-activating pill at the bottom-center of the screen under the mouse.
/// Never takes key focus, never steals the frontmost app.
@MainActor
final class HUDPanel: NSPanel {
    private let host = NSHostingView(rootView: HUDView(state: .idle))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(state: DictationState) {
        if case .idle = state { orderOut(nil); return }
        host.rootView = HUDView(state: state)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 64)
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}
```

- [ ] **Step 6: Build and commit**

Run: `swift build && swift test`
```bash
git add Sources/sAId/Core/DictationController.swift Sources/sAId/UI Sources/sAId/Audio/AudioCapture.swift Sources/sAId/Insert/TextInserter.swift Tests/sAIdTests/Fakes.swift Tests/sAIdTests/DictationControllerTests.swift
git commit -m "feat(core): dictation controller executes reducer effects; floating HUD panel"
```

---

### Task 10: App shell — menu bar, permissions, settings, history, xcodegen `.app`

**Files:**
- Create: `Sources/sAId/App/AppDelegate.swift`, `Sources/sAId/App/AppViewModel.swift`, `Sources/sAId/UI/MenuView.swift`, `Sources/sAId/UI/SettingsView.swift`, `Sources/sAId/UI/HistoryView.swift`, `Sources/sAId/UI/PermissionsView.swift`, `Sources/sAId/Support/History.swift`, `Sources/sAId/Support/Permissions.swift`, `project.yml`, `Info.plist`, `sAId.entitlements`, `Resources/MenuBarIcon.png` (22×22 template, or use SF Symbol)
- Modify: `Sources/sAId/App/sAIdApp.swift`
- Test: `Tests/sAIdTests/HistoryTests.swift`, `Tests/sAIdTests/PermissionsTests.swift`

**Interfaces:**
- Produces:
  - `struct HistoryEntry: Codable, Equatable, Identifiable { let id: UUID; let text: String; let date: Date }`
  - `final class History: Sendable { init(fileURL: URL, limit: Int = 50); func append(_ text: String); func all() -> [HistoryEntry]; func clear() }`
  - `struct PermissionStatus: Equatable { var microphone: Bool; var inputMonitoring: Bool; var accessibility: Bool; var allGranted: Bool }`
  - `enum Permissions { static func status() -> PermissionStatus; static func requestMicrophone() async -> Bool; static func requestInputMonitoring(); static func requestAccessibility(); static func openSystemSettings(pane: String) }`
  - `@MainActor final class AppViewModel: ObservableObject { @Published var state: DictationState; @Published var permissions: PermissionStatus; @Published var modelProgress: Double }`

- [ ] **Step 1: Write the failing tests**

`Tests/sAIdTests/HistoryTests.swift`:
```swift
import XCTest
@testable import sAId

final class HistoryTests: XCTestCase {
    func testAppendKeepsNewestFirstAndCapsAtLimit() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID()).json")
        let h = History(fileURL: url, limit: 3)
        ["a", "b", "c", "d"].forEach { h.append($0) }
        XCTAssertEqual(h.all().map(\.text), ["d", "c", "b"])
        XCTAssertEqual(History(fileURL: url, limit: 3).all().map(\.text), ["d", "c", "b"]) // persisted
        h.clear(); XCTAssertEqual(h.all(), [])
    }
}
```
`Tests/sAIdTests/PermissionsTests.swift`:
```swift
import XCTest
@testable import sAId

final class PermissionsTests: XCTestCase {
    func testAllGrantedRequiresAllThree() {
        XCTAssertTrue(PermissionStatus(microphone: true, inputMonitoring: true, accessibility: true).allGranted)
        XCTAssertFalse(PermissionStatus(microphone: true, inputMonitoring: false, accessibility: true).allGranted)
    }
}
```

- [ ] **Step 2: Run** — compile errors.

- [ ] **Step 3: Implement support types**

`Sources/sAId/Support/History.swift`:
```swift
import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID; let text: String; let date: Date
}

final class History: @unchecked Sendable {
    private let fileURL: URL; private let limit: Int
    private let lock = NSLock()
    private var entries: [HistoryEntry]

    init(fileURL: URL, limit: Int = 50) {
        self.fileURL = fileURL; self.limit = limit
        entries = (try? JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: fileURL))) ?? []
    }
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sAId/history.json")
    }
    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        entries.insert(HistoryEntry(id: UUID(), text: text, date: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }
    func all() -> [HistoryEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    func clear() { lock.lock(); entries = []; persist(); lock.unlock() }
    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
```

`Sources/sAId/Support/Permissions.swift`:
```swift
import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics

struct PermissionStatus: Equatable, Sendable {
    var microphone: Bool; var inputMonitoring: Bool; var accessibility: Bool
    var allGranted: Bool { microphone && inputMonitoring && accessibility }
}

enum Permissions {
    static func status() -> PermissionStatus {
        PermissionStatus(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         inputMonitoring: CGPreflightListenEventAccess(),
                         accessibility: AXIsProcessTrusted())
    }
    static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    static func requestInputMonitoring() { _ = CGRequestListenEventAccess() }
    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    static func openSystemSettings(pane: String) {
        // pane: "Privacy_Microphone" | "Privacy_ListenEvent" | "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
```

- [ ] **Step 4: Run the two tests** — `swift test --filter 'HistoryTests|PermissionsTests'` → pass.

- [ ] **Step 5: App wiring**

`Sources/sAId/App/AppViewModel.swift`:
```swift
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var state: DictationState = .loadingModels
    @Published var permissions = Permissions.status()
    @Published var modelProgress: Double = 0
    @Published var enabled = true
    @Published var lastError: String?
    func refreshPermissions() { permissions = Permissions.status() }
}
```

`Sources/sAId/App/AppDelegate.swift`:
```swift
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = AppViewModel()
    private var controller: DictationController!
    private var hotkey: HotkeyListener!
    private let hud = HUDPanel()
    private let history = History(fileURL: History.defaultURL)
    private let corrections = CorrectionsStore(fileURL: CorrectionsStore.defaultURL)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let correctionsList = corrections.load().isEmpty ? Self.bundledCorrections() : corrections.load()
        let post = PostProcess(corrections: correctionsList, fillers: Self.bundledFillers())
        let preview = MoonshinePreviewEngine(modelRoot: MoonshinePreviewEngine.defaultModelRoot)
        let final = Qwen3FinalEngine()
        let capture = AudioCapture(deviceUID: UserDefaults.standard.string(forKey: "inputDeviceUID"))
        let history = self.history
        controller = DictationController(capture: capture, preview: preview, final: final, sink: TextInserter(), post: post,
                                         history: { text in history.append(text) })
        Task { for await s in controller.states { self.viewModel.state = s; self.hud.show(state: s) } }

        let keycode = Int64(UserDefaults.standard.object(forKey: "hotkeyKeycode") as? Int ?? 61)
        hotkey = HotkeyListener(keycode: keycode) { [controller] action in Task { await controller?.hotkey(action) } }
        viewModel.refreshPermissions()
        if viewModel.permissions.allGranted { try? hotkey.start() } else { PermissionsWindow.show(viewModel: viewModel) { [weak self] in try? self?.hotkey.start() } }

        Task {
            do {
                try await preview.load(keyterms: correctionsList.map(\.to)) { p in Task { @MainActor in self.viewModel.modelProgress = p / 2 } }
                try await final.load { p, _ in Task { @MainActor in self.viewModel.modelProgress = 0.5 + p / 2 } }
                await controller.modelsReady()
            } catch {
                await controller.modelsFailed(String(describing: error))
            }
        }
    }

    static func bundledCorrections() -> [Correction] {
        guard let url = Bundle.main.url(forResource: "default-corrections", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Correction].self, from: data)) ?? []
    }
    static func bundledFillers() -> [String] {
        guard let url = Bundle.main.url(forResource: "default-fillers", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return ["um", "uh"] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? ["um", "uh"]
    }
}
```

`Sources/sAId/App/sAIdApp.swift`:
```swift
import SwiftUI

@main
struct sAIdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra { MenuView(viewModel: delegate.viewModel) } label: {
            Image(systemName: menuSymbol(delegate.viewModel.state))
        }
        Settings { SettingsView(viewModel: delegate.viewModel) }
    }

    private func menuSymbol(_ s: DictationState) -> String {
        switch s {
        case .listening: return "mic.fill"
        case .loadingModels: return "hourglass"
        case .error: return "mic.slash"
        default: return "mic"
        }
    }
}
```

`Sources/sAId/UI/MenuView.swift`:
```swift
import SwiftUI

struct MenuView: View {
    @ObservedObject var viewModel: AppViewModel
    var body: some View {
        Group {
            switch viewModel.state {
            case .loadingModels: Text("Loading models… \(Int(viewModel.modelProgress * 100))%")
            case .idle: Text("Ready — hold ⌥ to dictate")
            case .listening: Text("Listening…")
            case .finalizing: Text("Finalizing…")
            case .shown(let f): Text("Last: \(f.prefix(40))")
            case .error(let e): Text("Error: \(e)")
            }
        }
        Divider()
        Button("Copy last transcript") {
            if let last = History(fileURL: History.defaultURL).all().first {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(last.text, forType: .string)
            }
        }
        Button("History…") { HistoryWindow.show() }
        SettingsLink { Text("Settings…") }
        Button("Copy diagnostics") { Diagnostics.copy(viewModel: viewModel) }
        Divider()
        Button("Quit sAId") { NSApplication.shared.terminate(nil) }
    }
}

enum Diagnostics {
    @MainActor static func copy(viewModel: AppViewModel) {
        let p = viewModel.permissions
        let text = """
        sAId \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")
        state: \(viewModel.state)
        permissions: mic=\(p.microphone) inputMonitoring=\(p.inputMonitoring) accessibility=\(p.accessibility)
        hotkey keycode: \(UserDefaults.standard.object(forKey: "hotkeyKeycode") ?? 61)
        """
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
```

`Sources/sAId/UI/SettingsView.swift`:
```swift
import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @AppStorage("hotkeyKeycode") private var keycode: Int = 61
    @AppStorage("inputDeviceUID") private var inputDeviceUID: String = ""
    @State private var corrections: [Correction] = CorrectionsStore(fileURL: CorrectionsStore.defaultURL).load()
    private let store = CorrectionsStore(fileURL: CorrectionsStore.defaultURL)

    var body: some View {
        TabView {
            Form {
                Picker("Hotkey", selection: $keycode) {
                    Text("Right Option").tag(61); Text("Left Option").tag(58); Text("Right Command").tag(54)
                    Text("Fn / Globe").tag(63); Text("Keypad −").tag(78)
                }
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices, id: \.uniqueID) {
                        Text($0.localizedName).tag($0.uniqueID)
                    }
                }
                Text("Changes to hotkey and microphone apply after relaunch.").font(.footnote).foregroundStyle(.secondary)
            }.tabItem { Text("General") }.padding()

            VStack {
                Table(corrections) {
                    TableColumn("Heard") { c in Text(c.from) }
                    TableColumn("Replace with") { c in Text(c.to) }
                }
                HStack {
                    Button("Add") { corrections.append(Correction(from: "heard", to: "Replacement")) }
                    Button("Remove last") { _ = corrections.popLast() }
                    Spacer()
                    Button("Save") { try? store.save(corrections) }
                }
                Text("Whole-word, case-insensitive. Also boosts the live preview's vocabulary after relaunch.").font(.footnote).foregroundStyle(.secondary)
            }.tabItem { Text("Corrections") }.padding()

            Form {
                LabeledContent("Microphone", value: viewModel.permissions.microphone ? "Granted" : "Missing")
                LabeledContent("Input Monitoring", value: viewModel.permissions.inputMonitoring ? "Granted" : "Missing")
                LabeledContent("Accessibility", value: viewModel.permissions.accessibility ? "Granted" : "Missing")
                Button("Re-check") { viewModel.refreshPermissions() }
            }.tabItem { Text("Permissions") }.padding()
        }
        .frame(width: 520, height: 360)
    }
}
```
Make `Correction` `Identifiable` for `Table`: add `var id: String { from + "→" + to }` in an extension in `Corrections.swift`.

`Sources/sAId/UI/HistoryView.swift`:
```swift
import SwiftUI
import AppKit

struct HistoryView: View {
    @State private var entries = History(fileURL: History.defaultURL).all()
    var body: some View {
        List(entries) { e in
            VStack(alignment: .leading) {
                Text(e.text)
                Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            .contextMenu { Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.text, forType: .string) } }
        }
        .toolbar { Button("Clear") { History(fileURL: History.defaultURL).clear(); entries = [] } }
        .frame(minWidth: 480, minHeight: 320)
    }
}

@MainActor enum HistoryWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "sAId History"; w.contentView = NSHostingView(rootView: HistoryView()); w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
```

`Sources/sAId/UI/PermissionsView.swift`:
```swift
import SwiftUI
import AppKit

struct PermissionsView: View {
    @ObservedObject var viewModel: AppViewModel
    let onAllGranted: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("sAId needs three permissions").font(.title2)
            row("Microphone", viewModel.permissions.microphone) { Task { _ = await Permissions.requestMicrophone(); viewModel.refreshPermissions() } }
            row("Input Monitoring (to see the hotkey)", viewModel.permissions.inputMonitoring) { Permissions.requestInputMonitoring(); Permissions.openSystemSettings(pane: "Privacy_ListenEvent") }
            row("Accessibility (to paste)", viewModel.permissions.accessibility) { Permissions.requestAccessibility(); Permissions.openSystemSettings(pane: "Privacy_Accessibility") }
            HStack { Spacer(); Button("Re-check") { viewModel.refreshPermissions(); if viewModel.permissions.allGranted { onAllGranted() } } }
        }
        .padding(24).frame(width: 460)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            viewModel.refreshPermissions(); if viewModel.permissions.allGranted { onAllGranted() }
        }
    }
    private func row(_ title: String, _ ok: Bool, action: @escaping () -> Void) -> some View {
        HStack { Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary); Text(title); Spacer(); if !ok { Button("Grant…", action: action) } }
    }
}

@MainActor enum PermissionsWindow {
    private static var window: NSWindow?
    static func show(viewModel: AppViewModel, onAllGranted: @escaping () -> Void) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to sAId"
        w.contentView = NSHostingView(rootView: PermissionsView(viewModel: viewModel, onAllGranted: { onAllGranted(); w.close() }))
        w.center(); window = w; w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 6: xcodegen project**

`project.yml`:
```yaml
name: sAId
options:
  bundleIdPrefix: org.tvw
  deploymentTarget: { macOS: "15.0" }
  createIntermediateGroups: true
packages:
  speech-swift:
    url: https://github.com/soniqo/speech-swift.git
    revision: <same SHA as Package.swift>
  moonshine-swift:
    url: https://github.com/moonshine-ai/moonshine-swift.git
    from: 0.1.5
targets:
  sAId:
    type: application
    platform: macOS
    sources:
      - path: Sources/sAId
      - path: Resources
        type: folder
        buildPhase: resources
    dependencies:
      - package: speech-swift
        product: Qwen3ASR
      - package: moonshine-swift
        product: MoonshineVoice
    info:
      path: Info.plist
      properties:
        CFBundleName: sAId
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSUIElement: true
        LSMinimumSystemVersion: "15.0"
        NSMicrophoneUsageDescription: "sAId listens while you hold the hotkey."
        NSHumanReadableCopyright: "MIT © 2026 Scott Freeman"
    entitlements:
      path: sAId.entitlements
      properties:
        com.apple.security.device.audio-input: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.tvw.said
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
        DEVELOPMENT_TEAM: <Scott's team id — same as hAIvd-Assist>
  sAIdTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/sAIdTests]
    dependencies: [{ target: sAId }]
```
Fill `<same SHA…>` from Package.swift and `<Scott's team id>` from `security find-identity -v -p codesigning` (the Developer ID Application entry's team suffix). If no identity is available on the build machine, set `CODE_SIGN_IDENTITY: "-"` (ad-hoc) and note in the PR that TCC grants will reset per build.

- [ ] **Step 7: Generate, build the app, run tests**

Run:
```bash
xcodegen generate
xcodebuild -project sAId.xcodeproj -scheme sAId -configuration Debug -destination 'platform=macOS' build | tail -5
swift test
```
Expected: `** BUILD SUCCEEDED **`; all unit tests pass (engine contract tests skip).

- [ ] **Step 8: Commit**

```bash
git add Sources/sAId Resources project.yml Info.plist sAId.entitlements Tests/sAIdTests/HistoryTests.swift Tests/sAIdTests/PermissionsTests.swift
git commit -m "feat(app): menu bar shell, permissions checklist, settings, history; xcodegen .app"
```

---

### Task 11: End-to-end on hardware, bench and release scripts

**Files:**
- Create: `scripts/bench.sh`, `scripts/release.sh`, `Makefile`
- Modify: `docs/HANDOFF.md` (state after this task), `README.md` (usage)

**Interfaces:**
- Consumes: the `.app` from Task 10, `docs/SMOKE.md`.
- Produces: `make install` → `/Applications/sAId.app`; `scripts/bench.sh <wav-dir>` prints WER per engine; `scripts/release.sh` signs + notarizes + zips.

- [ ] **Step 1: Makefile**

```make
APP=build/Build/Products/Debug/sAId.app
.PHONY: build test app install
build: ; swift build
test: ; swift test
app: ; xcodegen generate && xcodebuild -project sAId.xcodeproj -scheme sAId -configuration Debug -destination 'platform=macOS' -derivedDataPath build build | tail -3
install: app ; rm -rf /Applications/sAId.app && cp -R $(APP) /Applications/sAId.app && open /Applications/sAId.app
```

- [ ] **Step 2: Bench script**

`scripts/bench.sh`:
```bash
#!/usr/bin/env bash
# Usage: scripts/bench.sh <dir with NN.wav + NN.txt reference pairs>
# Prints per-file and mean WER for the final engine. WAVs: 16 kHz mono PCM16.
set -euo pipefail
DIR="${1:?wav dir}"
swift build -c release --product said-bench >/dev/null
for wav in "$DIR"/*.wav; do
  ref="${wav%.wav}.txt"; [ -f "$ref" ] || continue
  hyp=$(.build/release/said-bench "$wav")
  python3 - "$ref" "$hyp" <<'EOF'
import sys,re
ref=re.findall(r"\w+",open(sys.argv[1]).read().lower()); hyp=re.findall(r"\w+",sys.argv[2].lower())
d=[[0]*(len(hyp)+1) for _ in range(len(ref)+1)]
for i in range(len(ref)+1): d[i][0]=i
for j in range(len(hyp)+1): d[0][j]=j
for i in range(1,len(ref)+1):
  for j in range(1,len(hyp)+1):
    d[i][j]=min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+(ref[i-1]!=hyp[j-1]))
print(f"{sys.argv[1]}: WER {100*d[-1][-1]/max(len(ref),1):.1f}%")
EOF
done
```
Add a tiny `said-bench` executable target to `Package.swift` (`Sources/said-bench/main.swift`) that reads a WAV path, loads `Qwen3FinalEngine`, prints the transcript. Keep it out of the app target. Test data: Scott records 20 sentences of his own jargon (`docs/bench/`) — the reference `.txt` files are typed by him.

- [ ] **Step 3: Release script**

`scripts/release.sh`:
```bash
#!/usr/bin/env bash
# Signs with Developer ID, notarizes, staples, zips. Requires: xcodegen, a "Developer ID Application"
# identity, and a notarytool keychain profile named "said-notary" (xcrun notarytool store-credentials).
set -euo pipefail
VERSION="${1:?version e.g. 0.1.0}"
xcodegen generate
xcodebuild -project sAId.xcodeproj -scheme sAId -configuration Release -derivedDataPath build build | tail -2
APP=build/Build/Products/Release/sAId.app
codesign --force --deep --options runtime --timestamp --sign "Developer ID Application" "$APP"
ditto -c -k --keepParent "$APP" "dist/sAId-$VERSION.zip"
xcrun notarytool submit "dist/sAId-$VERSION.zip" --keychain-profile said-notary --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "dist/sAId-$VERSION.zip"
echo "dist/sAId-$VERSION.zip"
```

- [ ] **Step 4: Hardware milestone (Scott, `docs/SMOKE.md` rows 1–14)**

`make install`, grant the three permissions, wait for "Ready", then in Notes: hold ⌥, speak, release. Pass = live words in the HUD, final text pasted, clipboard restored. Record the outcome and the model load time in `docs/HANDOFF.md`.

- [ ] **Step 5: Commit and PR**

```bash
git add Makefile scripts Package.swift Sources/said-bench docs/HANDOFF.md README.md
git commit -m "chore: Makefile, WER bench, release script; handoff updated after first hardware run"
```

---

## Self-review

**Spec coverage** — §2 modules: all eleven have a task (App/HUD/Settings/History/Permissions in 9–10; engines 7–8; audio 4; hotkey 5; insert 6; post 3; reducer/controller 2/9; Log 2). §2.2 transitions: every arrow is a reducer test in Task 2 (tap, cancel, cap, empty text, insert failure, engine failure, busy). §2.3 invariants: Task 4 test + comments; `Bundle.main` in Task 10. §3 model delivery: Tasks 7/8 (`ensureModelPresent`, `fromPretrained` offline-then-online). §4 HUD states: Task 9 `HUDView`. §5 post-processing incl. protected tokens: Task 3. §6 packaging/TCC: Task 10 `project.yml`, entitlement, hardened runtime; Task 11 release. §7 failure modes: secure input (6/9), paste failure (6/9), preview failure non-blocking (7: `try?`), final failure (9), tap timeout re-enable (5); device removal and sleep/wake are covered by `AudioCapture.stop/start` per press — add `AVAudioEngineConfigurationChange` handling as a follow-up ticket if row 16/17 of SMOKE fails. §8 tests: unit in 2–6, 9, 10; contract in 7–8; bench in 11; smoke in 11. §10 open question 1 answered by `setKeyterms` in Task 7.

**Placeholder scan** — the only fill-ins are values the implementer must read from the machine (speech-swift SHA, Developer ID team) and are given the exact command to obtain them. No TBDs.

**Type consistency** — `PreviewLine`, `FinalTranscriber`, `PreviewTranscriber` (Task 2) used unchanged in 7, 8, 9; `HotkeyAction` (5) consumed by `DictationController.hotkey` (9) and `AppDelegate` (10); `InsertError.secureInput` (6) matched in 9; `PostProcess(corrections:fillers:trailingSpace:)` (3) used in 9/10; `History.defaultURL`/`CorrectionsStore.defaultURL` (3/10) used in 10; `DictationController.currentState` (9) read in tests via `await`.
