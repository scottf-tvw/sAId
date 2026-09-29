@testable import SaidEngine
import XCTest
@testable import sAId

final class DictationReducerTests: XCTestCase {
    private let first = DictationSessionID(rawValue: 1)
    private let second = DictationSessionID(rawValue: 2)
    private let timer = DictationTimerID(rawValue: 1)

    private func ready() -> DictationState {
        DictationReducer.reduce(DictationState(), .modelsReady).0
    }

    @discardableResult
    private func send(_ state: inout DictationState, _ event: DictationEvent) -> [DictationEffect] {
        let result = DictationReducer.reduce(state, event)
        state = result.0
        return result.1
    }

    private func listening(seconds: Double = 1, preview: String = "preview") -> DictationState {
        var state = ready()
        send(&state, .hotkeyDown)
        send(&state, .audio(session: first, seconds: seconds))
        send(&state, .preview(session: first, line: PreviewLine(text: preview, isFinal: false)))
        return state
    }

    private func finalizing() -> DictationState {
        var state = listening()
        send(&state, .hotkeyUp)
        return state
    }

    private func inserting() -> DictationState {
        var state = finalizing()
        send(&state, .finalText(session: first, text: "Final output."))
        return state
    }

    func testInitiallyLoadingThenReady() {
        var state = DictationState()
        XCTAssertEqual(state.phase, .loadingModels)
        XCTAssertEqual(state.readiness, .loading)
        XCTAssertEqual(send(&state, .modelsReady), [])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.readiness, .ready)
    }

    func testLoadingRejectionTimerCannotOpenReadinessGate() {
        var state = DictationState()
        XCTAssertEqual(send(&state, .hotkeyDown), [.scheduleErrorClear(timer: timer, after: 2)])
        XCTAssertEqual(state.message, .error("Models still loading"))
        send(&state, .hotkeyUp)
        send(&state, .timerFired(timer))
        XCTAssertEqual(state.phase, .loadingModels)
        XCTAssertEqual(state.readiness, .loading)
        XCTAssertEqual(send(&state, .hotkeyDown), [.scheduleErrorClear(timer: .init(rawValue: 2), after: 2)])
    }

    func testModelsReadyWhileLoadingErrorIsDisplayedClearsGateAndOldTimer() {
        var state = DictationState()
        send(&state, .hotkeyDown)
        send(&state, .modelsReady)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.message)
        XCTAssertEqual(send(&state, .hotkeyDown), []) // Still physically held.
        send(&state, .hotkeyUp)
        send(&state, .hotkeyDown)
        send(&state, .timerFired(timer))
        XCTAssertEqual(state.phase, .listening(session: first, preview: "", seconds: 0))
    }

    func testModelFailureRemainsUnavailableAfterTransientError() {
        var state = DictationState()
        XCTAssertEqual(send(&state, .modelsFailed("missing")), [.log("models: missing")])
        XCTAssertEqual(state.readiness, .failed("missing"))
        send(&state, .hotkeyDown)
        send(&state, .hotkeyUp)
        send(&state, .timerFired(timer))
        XCTAssertEqual(state.phase, .error("Models failed: missing"))
        send(&state, .modelsReady)
        XCTAssertEqual(state.phase, .idle)
    }

    func testStartsCaptureAndPerSessionPreviewOnce() {
        var state = ready()
        XCTAssertEqual(send(&state, .hotkeyDown), [.startCapture(session: first), .startPreview(session: first)])
        XCTAssertTrue(state.previewActive)
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        XCTAssertEqual(state.phase, .listening(session: first, preview: "", seconds: 0))
    }

    func testPreviewAndAudioUpdateCurrentSessionOnly() {
        var state = listening(seconds: 1, preview: "words")
        send(&state, .audio(session: first, seconds: 0.064))
        send(&state, .preview(session: first, line: .init(text: "complete", isFinal: true)))
        XCTAssertEqual(state.phase, .listening(session: first, preview: "complete", seconds: 1.064))
        let before = state
        send(&state, .audio(session: second, seconds: 120))
        send(&state, .preview(session: second, line: .init(text: "stale", isFinal: false)))
        XCTAssertEqual(state, before)
    }

    func testInvalidAudioDurationsAreIgnored() {
        var state = listening()
        let before = state
        for seconds in [-1.0, 0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(send(&state, .audio(session: first, seconds: seconds)), [])
            XCTAssertEqual(state, before)
        }
    }

    func testTapThresholdUsesAudioAndExcludesBelow250Milliseconds() {
        var state = listening(seconds: 0.249)
        XCTAssertEqual(send(&state, .hotkeyUp), [.stopCapture(session: first), .stopPreview(session: first), .log("tap ignored (<0.25s)")])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.previewActive)
    }

    func testExactly250MillisecondsFinalizes() {
        var state = listening(seconds: 0.25)
        XCTAssertEqual(send(&state, .hotkeyUp), [.stopCapture(session: first), .stopPreview(session: first), .runFinal(session: first)])
        XCTAssertEqual(state.phase, .finalizing(session: first, preview: "preview"))
    }

    func testNoAudioReleaseDoesNotCallFinalEngine() {
        var state = ready()
        send(&state, .hotkeyDown)
        XCTAssertEqual(send(&state, .hotkeyUp), [.stopCapture(session: first), .stopPreview(session: first), .log("tap ignored (<0.25s)")])
        XCTAssertEqual(state.phase, .idle)
    }

    func testCapBoundaryAutomaticallyFinalizesOnce() {
        var state = listening(seconds: 119.99)
        XCTAssertEqual(send(&state, .audio(session: first, seconds: 0.01)), [.stopCapture(session: first), .stopPreview(session: first), .log("cap reached"), .runFinal(session: first)])
        XCTAssertEqual(state.phase, .finalizing(session: first, preview: "preview"))
        XCTAssertEqual(send(&state, .audio(session: first, seconds: 1)), [])
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        XCTAssertFalse(state.queuedStart)
    }

    func testCapOvershootDoesNotKeepListening() {
        var state = listening(seconds: 119.99)
        send(&state, .audio(session: first, seconds: 0.064))
        XCTAssertEqual(state.phase, .finalizing(session: first, preview: "preview"))
    }

    func testCancelStopsCaptureAndRequiresFreshPress() {
        var state = listening()
        XCTAssertEqual(send(&state, .cancel), [.stopCapture(session: first), .stopPreview(session: first)])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        send(&state, .hotkeyUp)
        XCTAssertEqual(send(&state, .hotkeyDown), [.startCapture(session: second), .startPreview(session: second)])
    }

    func testFinalTextEntersInsertingWithActualFinalAndNeverPreview() {
        var state = finalizing()
        XCTAssertEqual(send(&state, .finalText(session: first, text: "Final output.")), [.insert(session: first, text: "Final output.")])
        XCTAssertEqual(state.phase, .inserting(session: first, final: "Final output."))
        XCTAssertEqual(send(&state, .finalText(session: first, text: "duplicate")), [])
    }

    func testWhitespaceFinalIsSoftNothingHeardWithoutHistoryOrPaste() {
        var state = finalizing()
        send(&state, .hotkeyDown)
        XCTAssertEqual(send(&state, .finalText(session: first, text: " \n\t")), [.scheduleHide(timer: timer, after: 2)])
        XCTAssertEqual(state.phase, .nothingHeard)
        XCTAssertEqual(state.message, .nothingHeard)
        XCTAssertFalse(state.queuedStart)
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        send(&state, .timerFired(timer))
        XCTAssertEqual(state.phase, .idle)
    }

    func testInsertionSuccessRecordsAndShowsFinalThenHides() {
        var state = inserting()
        XCTAssertEqual(send(&state, .inserted(session: first)), [.record("Final output."), .scheduleHide(timer: timer, after: 0.6)])
        XCTAssertEqual(state.phase, .shown(final: "Final output."))
        send(&state, .timerFired(timer))
        XCTAssertEqual(state.phase, .idle)
    }

    func testInsertionFailureRecordsFinalThenDisplaysError() {
        var state = inserting()
        XCTAssertEqual(send(&state, .insertFailed(session: first, reason: "Secure input field")), [.record("Final output."), .scheduleErrorClear(timer: timer, after: 2)])
        XCTAssertEqual(state.phase, .error("Secure input field"))
        XCTAssertEqual(state.message, .error("Secure input field"))
        send(&state, .timerFired(timer))
        XCTAssertEqual(state.phase, .idle)
    }

    func testFinalEngineFailureRecordsPreviewAndWithdrawsQueue() {
        var state = finalizing()
        send(&state, .hotkeyDown)
        XCTAssertEqual(send(&state, .engineFailed(session: first, reason: "boom")), [.record("preview"), .log("engine: boom"), .scheduleErrorClear(timer: timer, after: 2)])
        XCTAssertEqual(state.phase, .error("Transcription failed"))
        XCTAssertFalse(state.queuedStart)
        XCTAssertEqual(send(&state, .hotkeyDown), [])
    }

    func testFinalEngineFailureWithEmptyPreviewDoesNotRecordEmptyHistory() {
        var state = listening(preview: "")
        send(&state, .hotkeyUp)
        XCTAssertEqual(send(&state, .engineFailed(session: first, reason: "boom")), [.log("engine: boom"), .scheduleErrorClear(timer: timer, after: 2)])
    }

    func testPreviewFailureStopsLiveTextAndKeepsFinalPath() {
        var state = listening()
        XCTAssertEqual(send(&state, .previewFailed(session: first, reason: "offline")), [.stopPreview(session: first), .log("preview: offline"), .scheduleErrorClear(timer: timer, after: 2)])
        XCTAssertEqual(state.message, .error("Live preview unavailable"))
        XCTAssertFalse(state.previewActive)
        send(&state, .preview(session: first, line: .init(text: "late", isFinal: true)))
        XCTAssertEqual(state.phase, .listening(session: first, preview: "preview", seconds: 1))
        XCTAssertEqual(send(&state, .hotkeyUp), [.stopCapture(session: first), .runFinal(session: first)])
    }

    func testCaptureFailureStopsBothPathsAndAllowsNewSessionAfterRelease() {
        var state = listening()
        XCTAssertEqual(send(&state, .captureFailed(session: first, reason: "Device disappeared")), [.stopCapture(session: first), .stopPreview(session: first), .scheduleErrorClear(timer: timer, after: 2)])
        XCTAssertEqual(state.phase, .error("Device disappeared"))
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        send(&state, .hotkeyUp)
        send(&state, .hotkeyDown)
        XCTAssertEqual(state.phase, .listening(session: second, preview: "", seconds: 0))
    }

    func testSecondPressDuringFinalizingWaitsThroughInsertion() {
        var state = finalizing()
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        XCTAssertTrue(state.queuedStart)
        XCTAssertEqual(send(&state, .finalText(session: first, text: "Final output.")), [.insert(session: first, text: "Final output.")])
        XCTAssertEqual(send(&state, .inserted(session: first)), [.record("Final output."), .startCapture(session: second), .startPreview(session: second)])
        XCTAssertEqual(state.phase, .listening(session: second, preview: "", seconds: 0))
        XCTAssertFalse(state.queuedStart)
    }

    func testSecondPressDuringInsertingQueues() {
        var state = inserting()
        send(&state, .hotkeyDown)
        XCTAssertTrue(state.queuedStart)
        send(&state, .inserted(session: first))
        XCTAssertEqual(state.phase, .listening(session: second, preview: "", seconds: 0))
    }

    func testReleaseWithdrawsQueuedIntentInEitherBusyPhase() {
        for initial in [finalizing(), inserting()] {
            var state = initial
            send(&state, .hotkeyDown)
            send(&state, .hotkeyUp)
            XCTAssertFalse(state.queuedStart)
            if case .finalizing = state.phase { send(&state, .finalText(session: first, text: "Final output.")) }
            XCTAssertEqual(send(&state, .inserted(session: first)), [.record("Final output."), .scheduleHide(timer: timer, after: 0.6)])
        }
    }

    func testCancelWithdrawsQueueWithoutCancelingCommittedInsertion() {
        for initial in [finalizing(), inserting()] {
            var state = initial
            send(&state, .hotkeyDown)
            XCTAssertEqual(send(&state, .cancel), [])
            XCTAssertFalse(state.queuedStart)
            XCTAssertEqual(send(&state, .hotkeyDown), [])
            if case .finalizing = state.phase { send(&state, .finalText(session: first, text: "Final output.")) }
            send(&state, .inserted(session: first))
            XCTAssertEqual(state.phase, .shown(final: "Final output."))
        }
    }

    func testRepressAfterQueueWithdrawalQueuesFreshIntent() {
        var state = finalizing()
        send(&state, .hotkeyDown)
        send(&state, .hotkeyUp)
        send(&state, .hotkeyDown)
        send(&state, .finalText(session: first, text: "Final output."))
        send(&state, .inserted(session: first))
        XCTAssertEqual(state.phase, .listening(session: second, preview: "", seconds: 0))
    }

    func testQueuedInsertionFailureRecordsBeforeStartingAndRetainsObservableError() {
        var state = inserting()
        send(&state, .hotkeyDown)
        XCTAssertEqual(send(&state, .insertFailed(session: first, reason: "Paste failed")), [.record("Final output."), .scheduleErrorClear(timer: timer, after: 2), .startCapture(session: second), .startPreview(session: second)])
        XCTAssertEqual(state.phase, .listening(session: second, preview: "", seconds: 0))
        XCTAssertEqual(state.message, .error("Paste failed"))
        send(&state, .timerFired(timer))
        XCTAssertNil(state.message)
        XCTAssertEqual(state.phase, .listening(session: second, preview: "", seconds: 0))
    }

    func testStaleTimerCannotHideNewSession() {
        var state = inserting()
        send(&state, .inserted(session: first))
        send(&state, .hotkeyDown)
        let before = state
        send(&state, .timerFired(timer))
        XCTAssertEqual(state, before)
    }

    func testStaleTimerCannotClearNewerError() {
        var state = inserting()
        send(&state, .insertFailed(session: first, reason: "first failure"))
        send(&state, .hotkeyDown)
        send(&state, .captureFailed(session: second, reason: "second failure"))
        let before = state
        send(&state, .timerFired(timer))
        XCTAssertEqual(state, before)
        send(&state, .timerFired(.init(rawValue: 2)))
        XCTAssertEqual(state.phase, .idle)
    }

    func testStaleAsyncResultsCannotAffectNextSession() {
        var state = inserting()
        send(&state, .hotkeyDown)
        send(&state, .inserted(session: first))
        let before = state
        for event in [DictationEvent.finalText(session: first, text: "stale"), .inserted(session: first), .insertFailed(session: first, reason: "stale"), .engineFailed(session: first, reason: "stale"), .captureFailed(session: first, reason: "stale"), .previewFailed(session: first, reason: "stale")] {
            XCTAssertEqual(send(&state, event), [])
            XCTAssertEqual(state, before)
        }
    }

    func testOutOfOrderCompletionCannotInsertOrRecordPreview() {
        var state = finalizing()
        let before = state
        XCTAssertEqual(send(&state, .inserted(session: first)), [])
        XCTAssertEqual(send(&state, .insertFailed(session: first, reason: "early")), [])
        XCTAssertEqual(state, before)
    }

    func testRepeatedSessionCompletesWithUniqueIdentityAndActualFinal() {
        var state = inserting()
        send(&state, .inserted(session: first))
        send(&state, .hotkeyDown)
        send(&state, .audio(session: second, seconds: 0.5))
        send(&state, .hotkeyUp)
        XCTAssertEqual(send(&state, .finalText(session: second, text: "Second final.")), [.insert(session: second, text: "Second final.")])
        XCTAssertEqual(send(&state, .inserted(session: second)), [.record("Second final."), .scheduleHide(timer: .init(rawValue: 2), after: 0.6)])
        XCTAssertEqual(state.phase, .shown(final: "Second final."))
    }

    func testDuplicateModelsReadyDoesNotInterruptListening() {
        var state = listening()
        let before = state
        send(&state, .modelsReady)
        XCTAssertEqual(state, before)
    }

    func testReadinessLossDuringInsertionCannotLoseFinalHistoryOnNewPress() {
        var state = inserting()
        send(&state, .modelsFailed("unavailable"))
        send(&state, .hotkeyDown)
        XCTAssertEqual(state.phase, .inserting(session: first, final: "Final output."))
        XCTAssertEqual(state.message, .error("Models failed: unavailable"))
        XCTAssertFalse(state.queuedStart)
        XCTAssertEqual(send(&state, .inserted(session: first)), [.record("Final output."), .scheduleHide(timer: .init(rawValue: 2), after: 0.6)])
        send(&state, .timerFired(.init(rawValue: 2)))
        XCTAssertEqual(state.phase, .error("Models failed: unavailable"))
    }

    func testReadinessLossDuringFinalizingRetainsOwnershipUntilCompletion() {
        var state = finalizing()
        XCTAssertEqual(send(&state, .modelsFailed("unavailable")), [.log("models: unavailable")])
        XCTAssertEqual(state.phase, .finalizing(session: first, preview: "preview"))
        XCTAssertEqual(send(&state, .finalText(session: first, text: "completed while unavailable")), [.record("preview"), .scheduleErrorClear(timer: timer, after: 2)])
        XCTAssertEqual(state.phase, .error("Models failed: unavailable"))
    }

    func testReadinessLossStopsListeningAndDoesNotStartQueuedCapture() {
        var state = listening()
        XCTAssertEqual(send(&state, .modelsFailed("unavailable")), [.log("models: unavailable"), .stopCapture(session: first), .stopPreview(session: first)])
        XCTAssertEqual(state.phase, .error("Models failed: unavailable"))
        XCTAssertFalse(state.previewActive)
        send(&state, .hotkeyUp)
        send(&state, .hotkeyDown)
        XCTAssertNil(state.session)
    }

    func testCapWithKeyStillHeldDoesNotRestartOnInsertionCompletion() {
        var state = listening(seconds: 119)
        send(&state, .audio(session: first, seconds: 1))
        send(&state, .finalText(session: first, text: "Final output."))
        XCTAssertEqual(send(&state, .inserted(session: first)), [.record("Final output."), .scheduleHide(timer: timer, after: 0.6)])
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        send(&state, .hotkeyUp)
        XCTAssertEqual(send(&state, .hotkeyDown), [.startCapture(session: second), .startPreview(session: second)])
    }

    func testPostprocessedBoundaryWhitespaceIsPreservedForInsertionAndSuccessHistory() {
        var state = finalizing()
        XCTAssertEqual(send(&state, .finalText(session: first, text: "\nHello. ")), [.insert(session: first, text: "\nHello. ")])
        XCTAssertEqual(state.phase, .inserting(session: first, final: "\nHello. "))
        XCTAssertEqual(send(&state, .inserted(session: first)), [.record("\nHello. "), .scheduleHide(timer: timer, after: 0.6)])
        XCTAssertEqual(state.phase, .shown(final: "\nHello. "))
    }

    func testOptInTrailingSpaceIsPreservedForInsertionFailureHistory() {
        var state = finalizing()
        XCTAssertEqual(send(&state, .finalText(session: first, text: "Hello. ")), [.insert(session: first, text: "Hello. ")])
        XCTAssertEqual(send(&state, .insertFailed(session: first, reason: "Paste failed")), [.record("Hello. "), .scheduleErrorClear(timer: timer, after: 2)])
    }

    func testReadinessRecoveryCannotStartCaptureBeforeOutstandingFinalAndInsertionFinish() {
        var state = finalizing()
        send(&state, .modelsFailed("unavailable"))
        send(&state, .modelsReady)
        XCTAssertEqual(state.phase, .finalizing(session: first, preview: "preview"))
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        XCTAssertTrue(state.queuedStart)
        XCTAssertEqual(send(&state, .finalText(session: first, text: "Final output.")), [.insert(session: first, text: "Final output.")])
        XCTAssertEqual(send(&state, .inserted(session: first)), [.record("Final output."), .startCapture(session: second), .startPreview(session: second)])
        XCTAssertEqual(state.phase, .listening(session: second, preview: "", seconds: 0))
    }

    func testReadinessRejectionAndNoticeTimerCannotReleaseOutstandingFinalOwnership() {
        var state = finalizing()
        send(&state, .modelsFailed("unavailable"))
        XCTAssertEqual(send(&state, .hotkeyDown), [.scheduleErrorClear(timer: timer, after: 2)])
        XCTAssertEqual(state.phase, .finalizing(session: first, preview: "preview"))
        send(&state, .timerFired(timer))
        XCTAssertEqual(state.phase, .finalizing(session: first, preview: "preview"))
        send(&state, .hotkeyUp)
        send(&state, .modelsReady)
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        XCTAssertEqual(state.session, first)
        XCTAssertTrue(state.queuedStart)
        XCTAssertEqual(send(&state, .engineFailed(session: first, reason: "inference failed")), [.record("preview"), .log("engine: inference failed"), .scheduleErrorClear(timer: .init(rawValue: 2), after: 2)])
        XCTAssertFalse(state.queuedStart)
        XCTAssertEqual(send(&state, .hotkeyDown), [])
        send(&state, .hotkeyUp)
        XCTAssertEqual(send(&state, .hotkeyDown), [.startCapture(session: second), .startPreview(session: second)])
    }
    func testCancelInvalidatesUnqueuedFinalAndInsertionCompletions() {
        for initial in [finalizing(), inserting()] {
            var state = initial
            send(&state, .cancel)
            XCTAssertEqual(state.phase, .idle)
            XCTAssertEqual(send(&state, .finalText(session: first, text: "stale")), [])
            XCTAssertEqual(send(&state, .inserted(session: first)), [])
            send(&state, .hotkeyDown)
            XCTAssertEqual(state.session, second)
        }
    }

    func testModelReloadStopsCaptureButRetainsOutstandingInferenceOwnership() {
        var capture = listening()
        XCTAssertEqual(send(&capture, .modelsLoading), [.stopCapture(session: first), .stopPreview(session: first)])
        XCTAssertEqual(capture.phase, .loadingModels)
        XCTAssertEqual(capture.readiness, .loading)
        for initial in [finalizing(), inserting()] {
            var state = initial
            send(&state, .modelsLoading)
            XCTAssertEqual(state.session, first)
            XCTAssertEqual(state.readiness, .loading)
            send(&state, .hotkeyDown)
            XCTAssertFalse(state.queuedStart)
        }
    }

}
