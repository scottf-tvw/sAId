/// Identities belong to a reducer/controller lifetime. Never reset state between utterances.
struct DictationSessionID: Sendable, Equatable, Hashable {
    let rawValue: UInt64
}

struct DictationTimerID: Sendable, Equatable, Hashable {
    let rawValue: UInt64
}

enum ModelReadiness: Sendable, Equatable {
    case loading
    case ready
    case failed(String)
}

enum DictationPhase: Sendable, Equatable {
    case loadingModels
    case idle
    case listening(session: DictationSessionID, preview: String, seconds: Double)
    case finalizing(session: DictationSessionID, preview: String)
    case inserting(session: DictationSessionID, final: String)
    case shown(final: String)
    case nothingHeard
    case error(String)
}

/// Transient HUD notices are independent of both model readiness and capture state.
/// For example a queued session may be listening while an insertion error is visible.
enum DictationMessage: Sendable, Equatable {
    case nothingHeard
    case error(String)
}

struct DictationState: Sendable, Equatable {
    var readiness: ModelReadiness = .loading
    var phase: DictationPhase = .loadingModels
    var message: DictationMessage?
    var hotkeyHeld = false
    var queuedStart = false
    var previewActive = false
    var activeTimer: DictationTimerID?
    var nextSessionID: UInt64 = 1
    var nextTimerID: UInt64 = 1

    var session: DictationSessionID? {
        switch phase {
        case .listening(let session, _, _), .finalizing(let session, _), .inserting(let session, _): session
        default: nil
        }
    }
}

enum DictationEvent: Sendable, Equatable {
    case modelsReady
    case modelsFailed(String)
    case hotkeyDown
    case hotkeyUp
    case cancel
    /// Audio duration comes from the captured sample count, never wall-clock key hold time.
    case audio(session: DictationSessionID, seconds: Double)
    case preview(session: DictationSessionID, line: PreviewLine)
    /// The controller supplies the final engine output after deterministic post-processing.
    case finalText(session: DictationSessionID, text: String)
    case inserted(session: DictationSessionID)
    case insertFailed(session: DictationSessionID, reason: String)
    case engineFailed(session: DictationSessionID, reason: String)
    case previewFailed(session: DictationSessionID, reason: String)
    case captureFailed(session: DictationSessionID, reason: String)
    case timerFired(DictationTimerID)
}

/// Ordered commands: the controller must finish capture/preview stops and drain audio
/// before executing runFinal. Every asynchronous completion returns its originating ID.
enum DictationEffect: Sendable, Equatable {
    case startCapture(session: DictationSessionID)
    case stopCapture(session: DictationSessionID)
    case startPreview(session: DictationSessionID)
    case stopPreview(session: DictationSessionID)
    case runFinal(session: DictationSessionID)
    case insert(session: DictationSessionID, text: String)
    case scheduleHide(timer: DictationTimerID, after: Double)
    case scheduleErrorClear(timer: DictationTimerID, after: Double)
    case record(String)
    case log(String)
}
