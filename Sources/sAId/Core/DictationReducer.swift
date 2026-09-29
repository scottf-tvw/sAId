import Foundation

struct DictationReducer: Sendable {
    static let minHoldSeconds = 0.25
    static let capSeconds = 120.0
    static let shownSeconds = 0.6
    static let errorSeconds = 2.0

    static func reduce(_ previous: DictationState, _ event: DictationEvent) -> (DictationState, [DictationEffect]) {
        var state = previous
        var effects: [DictationEffect] = []

        switch event {
        case .modelsReady:
            guard state.readiness != .ready else { return (previous, []) }
            state.readiness = .ready
            if state.session == nil {
                state.phase = .idle
                clearMessage(&state)
            }

        case .modelsFailed(let reason):
            state.readiness = .failed(reason)
            state.queuedStart = false
            effects.append(.log("models: \(reason)"))
            // Readiness changes do not complete outstanding inference or insertion.
            // Preserve ownership until its matching callback, preventing overlapping capture.
            switch state.phase {
            case .finalizing, .inserting:
                state.message = .error("Models failed: \(reason)")
                state.activeTimer = nil
            default:
                if case .listening(let session, _, _) = state.phase {
                    stopListening(&state, session: session, effects: &effects)
                }
                state.phase = .error("Models failed: \(reason)")
                state.message = .error("Models failed: \(reason)")
                state.activeTimer = nil
            }

        case .hotkeyDown:
            guard !state.hotkeyHeld else { return (previous, []) }
            state.hotkeyHeld = true
            guard state.readiness == .ready else {
                let message: String
                switch state.readiness {
                case .loading: message = "Models still loading"
                case .failed(let reason): message = "Models failed: \(reason)"
                case .ready: message = "Model not ready"
                }
                showError(&state, message: message, preservingPhase: state.session != nil, effects: &effects)
                return (state, effects)
            }
            switch state.phase {
            case .finalizing, .inserting:
                state.queuedStart = true
            case .listening:
                break
            default:
                startListening(&state, effects: &effects)
            }

        case .hotkeyUp:
            state.hotkeyHeld = false
            state.queuedStart = false
            if case .listening(let session, let preview, let seconds) = state.phase {
                stopListening(&state, session: session, effects: &effects)
                if seconds < minHoldSeconds {
                    state.phase = restingPhase(state.readiness)
                    effects.append(.log("tap ignored (<0.25s)"))
                } else {
                    state.phase = .finalizing(session: session, preview: preview)
                    effects.append(.runFinal(session: session))
                }
            }

        case .cancel:
            // Retain physical held state: Esc does not manufacture a fresh key press.
            state.queuedStart = false
            if case .listening(let session, _, _) = state.phase {
                stopListening(&state, session: session, effects: &effects)
                state.phase = restingPhase(state.readiness)
                clearMessage(&state)
            }

        case .audio(let session, let seconds):
            guard seconds.isFinite, seconds > 0,
                  case .listening(let current, let preview, let accumulated) = state.phase,
                  current == session else { return (previous, []) }
            let total = accumulated + seconds
            if total >= capSeconds {
                stopListening(&state, session: session, effects: &effects)
                state.phase = .finalizing(session: session, preview: preview)
                effects += [.log("cap reached"), .runFinal(session: session)]
            } else {
                state.phase = .listening(session: session, preview: preview, seconds: total)
            }

        case .preview(let session, let line):
            guard state.previewActive,
                  case .listening(let current, _, let seconds) = state.phase,
                  current == session else { return (previous, []) }
            state.phase = .listening(session: session, preview: line.text, seconds: seconds)

        case .finalText(let session, let text):
            guard case .finalizing(let current, let preview) = state.phase, current == session else { return (previous, []) }
            guard state.readiness == .ready else {
                state.queuedStart = false
                if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { effects.append(.record(preview)) }
                let message: String
                if case .failed(let reason) = state.readiness { message = "Models failed: \(reason)" }
                else { message = "Models still loading" }
                showError(&state, message: message, effects: &effects)
                return (state, effects)
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.queuedStart = false
                state.phase = .nothingHeard
                state.message = .nothingHeard
                effects.append(.scheduleHide(timer: newTimer(&state), after: errorSeconds))
            } else {
                state.phase = .inserting(session: session, final: text)
                effects.append(.insert(session: session, text: text))
            }

        case .inserted(let session):
            guard case .inserting(let current, let final) = state.phase, current == session else { return (previous, []) }
            effects.append(.record(final))
            if canStartQueued(state) {
                startListening(&state, effects: &effects)
            } else {
                state.queuedStart = false
                state.phase = .shown(final: final)
                state.message = nil
                effects.append(.scheduleHide(timer: newTimer(&state), after: shownSeconds))
            }

        case .insertFailed(let session, let reason):
            guard case .inserting(let current, let final) = state.phase, current == session else { return (previous, []) }
            let queued = canStartQueued(state)
            effects.append(.record(final))
            showError(&state, message: reason, effects: &effects)
            if queued {
                startListening(&state, preservingMessage: true, effects: &effects)
            } else {
                state.queuedStart = false
            }

        case .engineFailed(let session, let reason):
            guard case .finalizing(let current, let preview) = state.phase, current == session else { return (previous, []) }
            state.queuedStart = false
            if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { effects.append(.record(preview)) }
            effects.append(.log("engine: \(reason)"))
            showError(&state, message: "Transcription failed", effects: &effects)

        case .previewFailed(let session, let reason):
            guard state.previewActive,
                  case .listening(let current, _, _) = state.phase,
                  current == session else { return (previous, []) }
            state.previewActive = false
            effects += [.stopPreview(session: session), .log("preview: \(reason)")]

        case .captureFailed(let session, let reason):
            guard case .listening(let current, _, _) = state.phase, current == session else { return (previous, []) }
            stopListening(&state, session: session, effects: &effects)
            state.queuedStart = false
            showError(&state, message: reason, effects: &effects)

        case .timerFired(let timer):
            guard state.activeTimer == timer else { return (previous, []) }
            clearMessage(&state)
            switch state.phase {
            case .shown, .nothingHeard, .error: state.phase = restingPhase(state.readiness)
            default: break // Notice expiry must never stop a new capture or in-flight final.
            }
        }
        return (state, effects)
    }

    private static func restingPhase(_ readiness: ModelReadiness) -> DictationPhase {
        switch readiness {
        case .ready: .idle
        case .loading: .loadingModels
        case .failed(let reason): .error("Models failed: \(reason)")
        }
    }

    private static func clearMessage(_ state: inout DictationState) {
        state.message = nil
        state.activeTimer = nil
    }

    private static func newTimer(_ state: inout DictationState) -> DictationTimerID {
        let timer = DictationTimerID(rawValue: state.nextTimerID)
        state.nextTimerID += 1
        state.activeTimer = timer
        return timer
    }

    private static func showError(_ state: inout DictationState, message: String, preservingPhase: Bool = false, effects: inout [DictationEffect]) {
        if !preservingPhase { state.phase = .error(message) }
        state.message = .error(message)
        effects.append(.scheduleErrorClear(timer: newTimer(&state), after: errorSeconds))
    }

    private static func canStartQueued(_ state: DictationState) -> Bool {
        state.queuedStart && state.hotkeyHeld && state.readiness == .ready
    }

    private static func startListening(_ state: inout DictationState, preservingMessage: Bool = false, effects: inout [DictationEffect]) {
        let session = DictationSessionID(rawValue: state.nextSessionID)
        state.nextSessionID += 1
        state.phase = .listening(session: session, preview: "", seconds: 0)
        state.queuedStart = false
        state.previewActive = true
        if !preservingMessage { clearMessage(&state) }
        effects += [.startCapture(session: session), .startPreview(session: session)]
    }

    private static func stopListening(_ state: inout DictationState, session: DictationSessionID, effects: inout [DictationEffect]) {
        effects.append(.stopCapture(session: session))
        if state.previewActive { effects.append(.stopPreview(session: session)) }
        state.previewActive = false
    }
}
