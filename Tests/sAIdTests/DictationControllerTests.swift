import XCTest
@testable import sAId

@MainActor
final class DictationControllerTests: XCTestCase {
    func testReleaseDrainsQueuedSamplesBeforeThresholdAndPreservesOrder() async {
        let rig = ControllerRig(), controller = rig.controller()
        await rig.capture.configure(chunks: [[Float](repeating: 0.25, count: 2000), [Float](repeating: 0.5, count: 2000)])
        await controller.setModelReadiness(.ready)
        await controller.handle(.pressed, target: "first.app")
        await controller.handle(.released)
        await rig.history.waitForCount(1)
        let audio = await rig.engine.finalInputs.values
        XCTAssertEqual(audio, [[Float](repeating: 0.25, count: 2000) + [Float](repeating: 0.5, count: 2000)])
        let history = await rig.history.values
        XCTAssertEqual(history.first?.text, "Final words")
        XCTAssertEqual(history.first?.targetAppID, "first.app")
        XCTAssertEqual(history.first?.source, .final)
        await controller.shutdown()
    }
    func testCapTrimsExactlyAndDoesNotSelfAwait() async {
        let rig = ControllerRig(), controller = rig.controller()
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        await rig.capture.ready.waitForCount(1)
        await rig.capture.emit([Float](repeating: 0.5, count: 1_920_037))
        await rig.history.waitForCount(1)
        let inputs = await rig.engine.finalInputs.values
        XCTAssertEqual(inputs.map(\.count), [1_920_000])
        await controller.shutdown()
    }
    func testShortTapUsesAudioCount() async {
        let rig = ControllerRig(), controller = rig.controller()
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 3999)])
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        let state = await controller.currentState
        let finalInputs = await rig.engine.finalInputs.values
        XCTAssertEqual(state.phase, .idle); XCTAssertTrue(finalInputs.isEmpty)
        await controller.shutdown()
    }
    func testCaptureFailuresRecoverOnFreshPress() async {
        for startup in [true, false] {
            let rig = ControllerRig(), controller = rig.controller()
            await rig.capture.configure(fail: startup)
            await controller.setModelReadiness(.ready); await controller.handle(.pressed)
            if !startup { await rig.capture.ready.waitForCount(1); await rig.capture.fail() }
            _ = await state(controller) { if case .error = $0.phase { true } else { false } }
            await controller.handle(.released)
            await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
            await controller.handle(.pressed); await controller.handle(.released)
            await rig.history.waitForCount(1)
            await controller.shutdown()
        }
    }
    func testAllPreviewFailuresPreserveFinalAudioAndLogOnce() async {
        for failure in ["start", "feed", "event", "stop"] {
            let rig = ControllerRig(), controller = rig.controller()
            await rig.engine.configure(previewFailure: failure)
            await rig.capture.configure(chunks: [[Float](repeating: 0.75, count: 5000)])
            await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
            await rig.history.waitForCount(1)
            let audio = await rig.engine.finalInputs.values
            let logs = await rig.logs.values
            XCTAssertEqual(audio, [[Float](repeating: 0.75, count: 5000)])
            XCTAssertEqual(logs.filter { $0.contains("preview") }.count, 1, failure)
            await controller.shutdown()
        }
    }
    func testQueuedPressWaitsForInsertionCleanupAndKeepsTargets() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        await rig.sink.configure(gate: gate)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready); await controller.handle(.pressed, target: "one")
        await controller.handle(.released); await rig.sink.inputs.waitForCount(1)
        await controller.handle(.pressed, target: "two")
        let starts = await rig.capture.starts.values; XCTAssertEqual(starts.count, 1)
        await gate.release(); await rig.capture.starts.waitForCount(2)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.handle(.released); await rig.history.waitForCount(2)
        let history = await rig.history.values
        XCTAssertEqual(history.map(\.targetAppID), ["one", "two"])
        let cleaned = await rig.sink.cleaned.values; XCTAssertEqual(cleaned.count, 2)
        await controller.shutdown()
    }
    func testReleasedOrCanceledQueueDoesNotStart() async {
        for action in [HotkeyAction.released, .cancel] {
            let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
            await rig.engine.configure(finalGate: gate)
            await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
            await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
            await rig.engine.finalInputs.waitForCount(1)
            await controller.handle(.pressed)
            // Cancel during a queued press withdraws only the queue, preserving the first transcript.
            await controller.handle(action)
            await gate.release(); await rig.history.waitForCount(1)
            let starts = await rig.capture.starts.values; XCTAssertEqual(starts.count, 1)
            await controller.shutdown()
        }
    }
    func testFinalAndPreviewHistorySourcesAndSecureInputMessage() async {
        for finalFailure in [false, true] {
            let rig = ControllerRig(), controller = rig.controller()
            await rig.engine.configure(failFinal: finalFailure)
            await rig.sink.configure(failure: .secureInput)
            await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
            await controller.setModelReadiness(.ready); await controller.handle(.pressed, target: "target")
            await controller.handle(.released); await rig.history.waitForCount(1)
            let entries = await rig.history.values
            XCTAssertEqual(entries.first?.text, finalFailure ? "preview words" : "Final words")
            XCTAssertEqual(entries.first?.source, finalFailure ? .previewAfterFinalFailure : .final)
            XCTAssertEqual(entries.first?.targetAppID, "target")
            XCTAssertNotNil(entries.first?.failure)
            if finalFailure { let inputs = await rig.sink.inputs.values; XCTAssertTrue(inputs.isEmpty) }
            else { let current = await controller.currentState; XCTAssertEqual(current.message, .error("Secure input field")) }
            await controller.shutdown()
        }
    }
    func testEmptyPostprocessedOutputDoesNotInsertOrRecord() async {
        let rig = ControllerRig(), controller = rig.controller()
        await rig.engine.configure(final: "um")
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.configure(postProcess: PostProcess(trailingSpace: true))
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        _ = await state(controller) { $0.phase == .nothingHeard }
        let inputs = await rig.sink.inputs.values, entries = await rig.history.values
        XCTAssertTrue(inputs.isEmpty); XCTAssertTrue(entries.isEmpty)
        await controller.shutdown()
    }
    func testReadinessFailureTimerAndRecovery() async {
        let rig = ControllerRig(), controller = rig.controller()
        let initial = await controller.currentState; XCTAssertEqual(initial.phase, .loadingModels)
        await controller.handle(.pressed); await controller.handle(.released)
        await controller.setModelReadiness(.failed("offline"))
        await controller.handle(.pressed); await controller.handle(.released)
        let starts = await rig.capture.starts.values; XCTAssertTrue(starts.isEmpty)
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        let state = await controller.currentState
        if case .listening = state.phase {} else { XCTFail("Retry must allow listening") }
        await controller.shutdown()
    }
    func testConfigurationReplacesCaptureAndSnapshotsPostprocessing() async {
        let rig = ControllerRig(), controller = rig.controller(), replacement = ControllerCapture(), gate = ControllerGate()
        await rig.engine.configure(final: "hello", finalGate: gate)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        await rig.engine.finalInputs.waitForCount(1)
        await controller.configure(capture: replacement, postProcess: PostProcess(trailingSpace: true))
        await gate.release(); await rig.history.waitForCount(1)
        let entries = await rig.history.values; XCTAssertEqual(entries.first?.text, "Hello")
        await controller.handle(.pressed); await controller.handle(.cancel)
        let starts = await replacement.starts.values; XCTAssertEqual(starts.count, 1)
        await controller.shutdown()
    }
    func testShutdownWaitsForNativeFinalAndDiscardsLateResult() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate(), returned = ControllerJournal<Bool>()
        await rig.engine.configure(finalGate: gate)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        await rig.engine.finalInputs.waitForCount(1)
        let shutdown = Task { await controller.shutdown(); await returned.append(true) }
        _ = await state(controller) { $0.phase == .idle }
        let before = await returned.values; XCTAssertTrue(before.isEmpty)
        await gate.release(); await shutdown.value
        let entries = await rig.history.values, inputs = await rig.sink.inputs.values
        XCTAssertTrue(entries.isEmpty); XCTAssertTrue(inputs.isEmpty)
    }
    func testStopTimePreviewErrorStillLoggedAfterCancelInvalidatesPhase() async {
        let rig = ControllerRig(), controller = rig.controller()
        await rig.engine.configure(previewFailure: "stop")
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        await rig.engine.starts.waitForCount(1)
        await controller.handle(.cancel)
        let logs = await rig.logs.values
        XCTAssertEqual(logs.filter { $0.contains("preview") }.count, 1)
        await controller.shutdown()
    }
    func testPhysicalActionsRemainOrderedAcrossCaptureStartupAndReleaseDrain() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)], gate: gate)
        await controller.setModelReadiness(.ready)
        controller.send(.pressed, target: "first")
        await rig.capture.starts.waitForCount(1)
        controller.send(.released)
        controller.send(.pressed, target: "second")
        await gate.release()
        await rig.capture.starts.waitForCount(2)
        await controller.handle(.cancel)
        let entries = await rig.history.values
        XCTAssertEqual(entries.map(\.targetAppID), ["first"])
        await controller.shutdown()
    }
    func testSlowPreviewDoesNotBlockAudioAcceptance() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        await rig.engine.configure(feedGate: gate)
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        await rig.capture.ready.waitForCount(1)
        await rig.capture.emit([Float](repeating: 0.25, count: 4000))
        await rig.engine.feeds.waitForCount(1)
        await rig.capture.ready.waitForCount(1)
        await rig.capture.emit([Float](repeating: 0.5, count: 4000))
        _ = await state(controller) { if case .listening(_, _, let seconds) = $0.phase { seconds == 0.5 } else { false } }
        await gate.release(); await controller.handle(.released)
        await rig.history.waitForCount(1)
        let audio = await rig.engine.finalInputs.values
        XCTAssertEqual(audio, [[Float](repeating: 0.25, count: 4000) + [Float](repeating: 0.5, count: 4000)])
        await controller.shutdown()
    }
    func testCancelNativeFinalWaitsBeforeNextSessionAndDropsStaleText() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        await rig.engine.configure(finalGate: gate)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        await rig.engine.finalInputs.waitForCount(1)
        controller.send(.cancel)
        controller.send(.pressed, target: "fresh")
        _ = await state(controller) { $0.phase == .idle }
        let starts = await rig.capture.starts.values; XCTAssertEqual(starts.count, 1)
        await gate.release(); await rig.capture.starts.waitForCount(2)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.handle(.released); await rig.history.waitForCount(1)
        let entries = await rig.history.values
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?.targetAppID, "fresh")
        await controller.shutdown()
    }
    func testActiveDeviceReplacementDrainsOldSourceBeforeUsingNewSource() async {
        let rig = ControllerRig(), controller = rig.controller(), replacement = ControllerCapture()
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        await rig.capture.ready.waitForCount(1)
        await rig.capture.emit([Float](repeating: 0.1, count: 4000))
        await controller.configure(capture: replacement)
        let stopped = await rig.capture.stops.values; XCTAssertEqual(stopped.count, 1)
        await controller.handle(.released)
        await replacement.configure(chunks: [[Float](repeating: 0.8, count: 4000)])
        await controller.handle(.pressed); await controller.handle(.released)
        await rig.history.waitForCount(1)
        let audio = await rig.engine.finalInputs.values
        XCTAssertEqual(audio, [[Float](repeating: 0.8, count: 4000)])
        await controller.shutdown()
    }
    func testDisableAndShutdownWaitForInsertionCleanup() async {
        for shutdown in [false, true] {
            let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate(), done = ControllerJournal<Bool>()
            await rig.sink.configure(gate: gate)
            await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
            await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
            await rig.sink.inputs.waitForCount(1)
            let stop = Task {
                if shutdown { await controller.shutdown() }
                else { await controller.setEnabled(false, reason: "Microphone permission lost") }
                await done.append(true)
            }
            _ = await state(controller) { $0.phase == .idle }
            let before = await done.values; XCTAssertTrue(before.isEmpty)
            await gate.release(); await stop.value
            let cleaned = await rig.sink.cleaned.values; XCTAssertEqual(cleaned.count, 1)
            if !shutdown {
                let unavailable = await controller.currentState
                XCTAssertEqual(unavailable.message, .error("Microphone permission lost"))
                await controller.handle(.pressed)
                let starts = await rig.capture.starts.values; XCTAssertEqual(starts.count, 1)
                await controller.setEnabled(true); await controller.handle(.pressed)
                let restarted = await rig.capture.starts.values; XCTAssertEqual(restarted.count, 2)
                await controller.shutdown()
            }
        }
    }
    func testTwoSessionsHaveFreshPreviewStreams() async {
        let rig = ControllerRig(), controller = rig.controller()
        await controller.setModelReadiness(.ready)
        for index in 1...2 {
            await controller.handle(.pressed)
            await rig.capture.ready.waitForCount(index)
            await rig.capture.emit([Float](repeating: 0, count: 4000))
            _ = await state(controller) { if case .listening(_, let preview, _) = $0.phase { preview == "preview words" } else { false } }
            await controller.handle(.released); await rig.history.waitForCount(index)
        }
        let starts = await rig.engine.starts.values; XCTAssertEqual(starts.count, 2)
        await controller.shutdown()
    }
    func testShutdownCancelsStartupAndStillWaitsForQuiescence() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        let canceled = expectation(description: "Capture start receives cancellation")
        await rig.capture.configure(gate: gate, cancelled: { canceled.fulfill() })
        await controller.setModelReadiness(.ready); controller.send(.pressed)
        await rig.capture.starts.waitForCount(1)
        let shutdown = Task { await controller.shutdown() }
        // The timeout only bounds a broken implementation; the cancellation callback is the barrier.
        await fulfillment(of: [canceled], timeout: 2)
        await gate.release(); await shutdown.value
        let stopped = await rig.capture.stops.values
        XCTAssertEqual(stopped.count, 1)
    }
    func testShownTimerUses600MillisecondsAndCannotHideNewListening() async {
        let rig = ControllerRig(), clock = ControllerClock()
        let controller = DictationController(capture: rig.capture, preview: rig.engine, final: rig.engine,
                                              sink: rig.sink, record: { await rig.history.append($0) },
                                              delay: { try await clock.delay($0) })
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        await clock.requests.waitForCount(1)
        let intervals = await clock.requests.values; XCTAssertEqual(intervals, [.milliseconds(600)])
        await controller.handle(.pressed)
        var snapshots = await controller.states().makeAsyncIterator()
        let before = await snapshots.next()
        await clock.fire(0)
        let after = await snapshots.next()
        XCTAssertEqual(after, before)
        if case .listening = after?.phase {} else { XCTFail("Old hide timer must not hide capture") }
        await controller.shutdown()
    }
    func testLoadingErrorTimerExpiresAfterTwoSecondsWithoutEnablingCapture() async {
        let rig = ControllerRig(), clock = ControllerClock()
        let controller = DictationController(capture: rig.capture, preview: rig.engine, final: rig.engine,
                                              sink: rig.sink, delay: { try await clock.delay($0) })
        var snapshots = await controller.states().makeAsyncIterator()
        let initial = await snapshots.next(); XCTAssertEqual(initial?.phase, .loadingModels)
        await controller.handle(.pressed); await controller.handle(.released)
        await clock.requests.waitForCount(1)
        let intervals = await clock.requests.values; XCTAssertEqual(intervals, [.seconds(2)])
        await clock.fire(0)
        _ = await state(controller) { $0.message == nil }
        await controller.handle(.pressed)
        let state = await controller.currentState
        XCTAssertEqual(state.readiness, .loading)
        let starts = await rig.capture.starts.values; XCTAssertTrue(starts.isEmpty)
        await controller.shutdown()
    }
    func testFragmentedSamplesAtExactly250MillisecondsCannotRoundDownToTap() async {
        let rig = ControllerRig(), controller = rig.controller()
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        await rig.capture.ready.waitForCount(1)
        await rig.capture.emit([0])
        _ = await state(controller) { if case .listening(_, _, let seconds) = $0.phase { seconds > 0 } else { false } }
        await rig.capture.emit([Float](repeating: 0, count: 3002))
        _ = await state(controller) { if case .listening(_, _, let seconds) = $0.phase { seconds > 0.18 } else { false } }
        await rig.capture.emit([Float](repeating: 0, count: 997))
        _ = await state(controller) { if case .listening(_, _, let seconds) = $0.phase { seconds > 0.249 } else { false } }
        await controller.handle(.released)
        let current = await controller.currentState
        guard current.phase != .idle else {
            XCTFail("Exactly 4000 samples must transcribe despite floating-point accumulation")
            await controller.shutdown(); return
        }
        await rig.history.waitForCount(1)
        let inputs = await rig.engine.finalInputs.values; XCTAssertEqual(inputs.map(\.count), [4000])
        await controller.shutdown()
    }
    private func state(_ controller: DictationController, matching: @Sendable (DictationState) -> Bool) async -> DictationState? {
        for await value in await controller.states() { if matching(value) { return value } }
        return nil
    }
}
