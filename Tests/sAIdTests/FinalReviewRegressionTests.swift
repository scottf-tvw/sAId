import CoreGraphics
import XCTest
@testable import sAId

@MainActor
final class FinalReviewRegressionTests: XCTestCase {
    private func event(_ type: CGEventType, _ key: UInt16, flags: UInt64 = 0, origin: Int64 = 0) -> HotkeyEventSnapshot {
        .init(typeRawValue: type.rawValue, keycode: key, flagsRawValue: flags, isAutoRepeat: false, sourceUserData: origin)
    }
    func testPhysicalEscapeAfterReleaseCancelsGatedFinalAndAwaitsCleanup() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        await rig.engine.configure(finalGate: gate)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready)
        let tap = RegressionTap(), listener = HotkeyListener(tap: tap)
        listener.canCancel = { controller.canCancel }
        listener.onAction = { HotkeyControllerBridge.send($0, to: controller) }
        XCTAssertTrue(listener.start())
        XCTAssertFalse(tap.send(event(.keyDown, 53))) // Idle Escape passes through.
        _ = tap.send(event(.flagsChanged, 61, flags: CGEventFlags.maskAlternate.rawValue))
        _ = tap.send(event(.flagsChanged, 61))
        await rig.engine.finalInputs.waitForCount(1)
        XCTAssertFalse(tap.send(event(.keyDown, 53, origin: EventOrigin.insertion)))
        let suppressed = tap.send(event(.keyDown, 53))
        XCTAssertTrue(suppressed, "Physical Escape must cancel after the hold was released")
        if suppressed {
            for await state in await controller.states() { if state.phase == .idle { break } }
            let done = ControllerJournal<Bool>()
            let barrier = Task { await controller.configure(); await done.append(true) }
            let before = await done.values; XCTAssertTrue(before.isEmpty)
            await gate.release(); await barrier.value
            let inserted = await rig.sink.inputs.values, history = await rig.history.values
            XCTAssertTrue(inserted.isEmpty); XCTAssertTrue(history.isEmpty)
            let starts = await rig.capture.starts.values; XCTAssertEqual(starts.count, 1)
            XCTAssertTrue(tap.send(event(.keyUp, 53)))
            XCTAssertFalse(tap.send(event(.keyDown, 53)))
        } else { await gate.release() }
        listener.stop(); await controller.shutdown()
    }
    func testPhysicalEscapeSeesPendingPressWhilePriorCleanupBlocksMailbox() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        await rig.engine.configure(finalGate: gate)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready)
        await controller.handle(.pressed); await controller.handle(.released)
        await rig.engine.finalInputs.waitForCount(1)
        controller.send(.cancel)
        for await state in await controller.states() { if state.phase == .idle { break } }
        XCTAssertFalse(controller.canCancel)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        // Cleanup is genuinely blocked on inference. No UI observer is installed.
        let tap = RegressionTap(), listener = HotkeyListener(tap: tap)
        listener.canCancel = { controller.canCancel }
        listener.onAction = { HotkeyControllerBridge.send($0, to: controller) }
        XCTAssertTrue(listener.start())
        _ = tap.send(event(.flagsChanged, 61, flags: CGEventFlags.maskAlternate.rawValue))
        _ = tap.send(event(.flagsChanged, 61))
        XCTAssertTrue(controller.canCancel)
        XCTAssertTrue(tap.send(event(.keyDown, 53)))
        await gate.release(); await controller.configure()
        let state = await controller.currentState, history = await rig.history.values
        XCTAssertNil(state.session); XCTAssertFalse(state.hotkeyHeld)
        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(controller.canCancel)
        listener.stop(); await controller.shutdown()
    }
    func testPhysicalEscapeWithdrawsQueuedHoldButPreservesOriginalFinal() async {
        let rig = ControllerRig(), controller = rig.controller(), gate = ControllerGate()
        await rig.engine.configure(finalGate: gate)
        await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
        await controller.setModelReadiness(.ready)
        let tap = RegressionTap(), listener = HotkeyListener(tap: tap)
        listener.canCancel = { controller.canCancel }
        listener.onAction = { HotkeyControllerBridge.send($0, to: controller) }
        XCTAssertTrue(listener.start())
        _ = tap.send(event(.flagsChanged, 61, flags: CGEventFlags.maskAlternate.rawValue))
        _ = tap.send(event(.flagsChanged, 61))
        await rig.engine.finalInputs.waitForCount(1)
        _ = tap.send(event(.flagsChanged, 61, flags: CGEventFlags.maskAlternate.rawValue))
        XCTAssertTrue(tap.send(event(.keyDown, 53)))
        await controller.configure()
        let withdrawn = await controller.currentState
        XCTAssertFalse(withdrawn.queuedStart); XCTAssertFalse(withdrawn.hotkeyHeld)
        if case .finalizing = withdrawn.phase { } else { XCTFail("Original final must survive queued withdrawal") }
        _ = tap.send(event(.flagsChanged, 61))
        await gate.release(); await rig.history.waitForCount(1)
        let starts = await rig.capture.starts.values; XCTAssertEqual(starts.count, 1)
        listener.stop(); await controller.shutdown()
    }
    func testExactSampleCapNoticeUsesControllerTimerWhileFinalRemainsGated() async {
        let rig = ControllerRig(), clock = ControllerClock(), gate = ControllerGate()
        await rig.engine.configure(finalGate: gate)
        let controller = DictationController(capture: rig.capture, preview: rig.engine, final: rig.engine, sink: rig.sink,
                                            delay: { try await clock.delay($0) })
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        await rig.capture.ready.waitForCount(1)
        await rig.capture.emit([Float](repeating: 0, count: 1_920_000))
        await rig.engine.finalInputs.waitForCount(1); await clock.requests.waitForCount(1)
        let capped = await controller.currentState, intervals = await clock.requests.values
        XCTAssertEqual(HUDPresentation(capped).notice, "120-second limit reached — finishing")
        XCTAssertEqual(intervals, [.seconds(2)])
        await clock.fire(0)
        for await state in await controller.states() { if state.message == nil { break } }
        let expired = await controller.currentState
        XCTAssertEqual(expired.phase, capped.phase)
        XCTAssertTrue(expired.hotkeyHeld)
        let inserted = await rig.sink.inputs.values; XCTAssertTrue(inserted.isEmpty)
        controller.send(.cancel)
        await gate.release(); await controller.shutdown()
    }
    func testCapNoticeExpiresWithoutChangingFinalAndStaleTimerCannotClearNewNotice() {
        var state = DictationReducer.reduce(DictationState(), .modelsReady).0
        state = DictationReducer.reduce(state, .hotkeyDown).0
        let first = state.session!
        state = DictationReducer.reduce(state, .preview(session: first, line: .init(text: "frozen preview", isFinal: false))).0
        let (capped, effects) = DictationReducer.reduce(state, .audio(session: first, seconds: 120))
        XCTAssertEqual(capped.phase, .finalizing(session: first, preview: "frozen preview"))
        XCTAssertEqual(HUDPresentation(capped).notice, "120-second limit reached — finishing")
        XCTAssertEqual(HUDPresentation(capped).activity, .finalizing)
        guard let timer = capped.activeTimer else { XCTFail("Cap notice must expire"); return }
        XCTAssertTrue(effects.contains(.scheduleErrorClear(timer: timer, after: 2)))
        let expired = DictationReducer.reduce(capped, .timerFired(timer)).0
        XCTAssertNil(HUDPresentation(expired).notice); XCTAssertEqual(expired.phase, capped.phase)
        state = DictationReducer.reduce(capped, .cancel).0
        state = DictationReducer.reduce(state, .hotkeyUp).0
        state = DictationReducer.reduce(state, .hotkeyDown).0
        let second = state.session!
        state = DictationReducer.reduce(state, .audio(session: second, seconds: 120)).0
        let before = state
        state = DictationReducer.reduce(state, .timerFired(timer)).0
        XCTAssertEqual(state, before)
        state = DictationReducer.reduce(state, .preview(session: first, line: .init(text: "stale", isFinal: false))).0
        XCTAssertEqual(state, before)
    }
    func testCaptureFailuresLogOnceWithoutLeakingErrorPayload() async {
        for (error, category) in [(NSError(domain: "private microphone and transcript payload", code: 123) as any Error, "unknown"),
                                  (AudioCaptureError.coreAudio(-50), "coreAudio(-50)"),
                                  (AudioCaptureError.deviceUnavailable, "deviceUnavailable")] {
            for startup in [true, false] {
                let rig = ControllerRig(), capture = DiagnosticCapture(startup: startup, error: error)
                let controller = DictationController(capture: capture, preview: rig.engine, final: rig.engine, sink: rig.sink,
                                                    log: { await rig.logs.append($0) })
                await controller.setModelReadiness(.ready); await controller.handle(.pressed)
                for await state in await controller.states() { if case .error = state.phase { break } }
                await controller.handle(.released); await controller.shutdown()
                let logs = await rig.logs.values
                XCTAssertEqual(logs, [(startup ? "capture start: " : "capture stream: ") + category])
            }
        }
    }
    func testInsertionFailuresLogOnceAndKeepFinalHistoryAfterCleanup() async {
        let failures: [(any Error, String)] = [
            (TextInsertionError.permissionUnavailable, "permissionUnavailable"),
            (TextInsertionError.eventCreationFailed, "eventCreationFailed"),
            (TextInsertionError.clipboardWriteFailed, "clipboardWriteFailed"),
            (TextInsertionError.clipboardRestoreFailed, "clipboardRestoreFailed"),
            (NSError(domain: "private clipboard and correction contents", code: 1), "unknown")
        ]
        for (error, category) in failures {
            let rig = ControllerRig(), sink = DiagnosticSink(error: error)
            let controller = DictationController(capture: rig.capture, preview: rig.engine, final: rig.engine, sink: sink,
                                                record: { await rig.history.append($0) }, log: { await rig.logs.append($0) })
            await rig.capture.configure(chunks: [[Float](repeating: 0, count: 4000)])
            await rig.engine.configure(final: "private transcript")
            await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
            await rig.history.waitForCount(1); await controller.shutdown()
            let logs = await rig.logs.values, history = await rig.history.values
            XCTAssertEqual(logs, ["insert: " + category])
            XCTAssertEqual(history.first?.text, "Private transcript")
            XCTAssertEqual(history.first?.failure, "Paste failed — copy from History")
        }
    }
}

@MainActor
private final class RegressionTap: HotkeyTap {
    var handler: (@MainActor (HotkeyEventSnapshot) -> Bool)?
    func start(handler: @escaping @MainActor (HotkeyEventSnapshot) -> Bool) -> Bool { self.handler = handler; return true }
    func stop() { handler = nil }
    func enable() { }
    func isKeyDown(_ keycode: UInt16) -> Bool { false }
    func send(_ event: HotkeyEventSnapshot) -> Bool { handler?(event) ?? false }
}
private struct DiagnosticCapture: CaptureSource {
    let startup: Bool
    let error: any Error
    func start() async throws -> AsyncThrowingStream<[Float], Error> {
        if startup { throw error }
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func stop() async { }
}
private struct DiagnosticSink: TextSink {
    let error: any Error
    func insert(_ text: String) async throws { throw error }
}
