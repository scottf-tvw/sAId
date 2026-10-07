import Foundation
import Synchronization

/// An allowlist of durations/categories only; never retains audio, text, targets or errors.
struct DictationTiming: Sendable, Equatable {
    enum Stage: String, Sendable, CaseIterable {
        case mailboxWait = "Release mailbox wait"
        case captureDrain = "Capture stop/drain"
        case previewDrain = "Preview drain wait"
        case previewStop = "Preview stop call (native decode/events)"
        case finalInference = "Whole-utterance final inference"
        case postProcess = "Text processing"
        case finalDispatchWait = "Final result mailbox wait"
        case insertion = "Insertion posting/cleanup"
    }
    enum Trigger: String, Sendable { case release, audioCap }
    enum Outcome: String, Sendable { case inserted, canceled, captureFailed, finalFailed, insertionFailed, shortTap, nothingHeard, unavailable }
    let session: DictationSessionID
    let trigger: Trigger?
    let outcome: Outcome
    let stages: [Stage: Duration]
    let finishToCompletion: Duration?

    var diagnosticText: String {
        var lines = ["Last session timing: \(session.rawValue) / \(outcome.rawValue)", "Finish trigger: \(trigger?.rawValue ?? "none")"]
        for stage in Stage.allCases {
            if let duration = stages[stage] { lines.append("\(stage.rawValue): \(Self.milliseconds(duration)) ms") }
        }
        if let finishToCompletion { lines.append("Finish to controller completion: \(Self.milliseconds(finishToCompletion)) ms") }
        lines.append("Preview stop normally overlaps drain; failure/cancellation may stop earlier. Do not add them.")
        lines.append("Insertion timing includes posting/cleanup; target acceptance is not measured.")
        return lines.joined(separator: "\n")
    }
    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.1f", Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }
}

/// Shared only by the controller and its owned workers. Locks never span an await.
final class DictationTimingRecorder: Sendable {
    private struct State: Sendable {
        var trigger: DictationTiming.Trigger?
        var finishStarted: Duration?
        var starts: [DictationTiming.Stage: Duration] = [:]
        var stages: [DictationTiming.Stage: Duration] = [:]
        var finished = false
    }
    let session: DictationSessionID
    private let state = Mutex(State())
    private let now: @Sendable () -> Duration
    init(session: DictationSessionID, now: @escaping @Sendable () -> Duration) { self.session = session; self.now = now }
    func trigger(_ trigger: DictationTiming.Trigger, at received: Duration) {
        let current = now()
        state.withLock {
            guard !$0.finished, $0.trigger == nil else { return }
            $0.trigger = trigger; $0.finishStarted = received
            if trigger == .release { $0.stages[.mailboxWait] = max(.zero, current - received) }
        }
    }
    func begin(_ stage: DictationTiming.Stage) {
        let current = now()
        state.withLock {
            guard !$0.finished, $0.starts[stage] == nil, $0.stages[stage] == nil else { return }
            $0.starts[stage] = current
        }
    }
    func end(_ stage: DictationTiming.Stage) {
        let current = now()
        state.withLock {
            guard !$0.finished, let start = $0.starts.removeValue(forKey: stage) else { return }
            $0.stages[stage] = max(.zero, current - start)
        }
    }
    func wait(_ stage: DictationTiming.Stage, since received: Duration) {
        let current = now()
        state.withLock { if !$0.finished { $0.stages[stage] = max(.zero, current - received) } }
    }
    func finish(_ outcome: DictationTiming.Outcome) -> DictationTiming {
        let current = now()
        return state.withLock {
            $0.finished = true
            return DictationTiming(session: session, trigger: $0.trigger, outcome: outcome, stages: $0.stages,
                                   finishToCompletion: $0.finishStarted.map { max(.zero, current - $0) })
        }
    }
}
