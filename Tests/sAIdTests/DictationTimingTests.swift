import XCTest
import SaidEngine
import Synchronization
@testable import sAId

/// The clock advances only at controlled dependency boundaries; no wall-clock sleeps.
private final class TimingClock: Sendable {
    private let value = Mutex(Duration.zero)
    func now() -> Duration { value.withLock { $0 } }
    func advance(_ ms: Int) { value.withLock { $0 += .milliseconds(ms) } }
}
private actor TimedCapture: CaptureSource {
    let clock: TimingClock
    var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    var samples = 4000
    var startGate: ControllerGate?
    let ready = ControllerJournal<Int>()
    var count = 0
    init(_ clock: TimingClock) { self.clock = clock }
    func setSamples(_ count: Int) { samples = count }
    func setGate(_ gate: ControllerGate) { startGate = gate }
    func emit(_ count: Int) { continuation?.yield(Array(repeating: 0.5, count: count)) }
    func start() async -> AsyncThrowingStream<[Float], Error> {
        await startGate?.wait()
        let pair = AsyncThrowingStream<[Float], Error>.makeStream(); continuation = pair.continuation
        count += 1; await ready.append(count)
        return pair.stream
    }
    func stop() { clock.advance(10); continuation?.yield(Array(repeating: 0.5, count: samples)); continuation?.finish() }
}
private actor TimedEngine: PreviewTranscriber, FinalTranscriber {
    let clock: TimingClock
    let started = ControllerJournal<Int>()
    let stopped = ControllerJournal<Int>()
    var continuation: AsyncThrowingStream<PreviewLine, Error>.Continuation?
    var failure = false
    var gate: ControllerGate?
    var count = 0
    init(_ clock: TimingClock) { self.clock = clock }
    func configure(failure: Bool = false, gate: ControllerGate? = nil) { self.failure = failure; self.gate = gate }
    func start() -> AsyncThrowingStream<PreviewLine, Error> {
        let pair = AsyncThrowingStream<PreviewLine, Error>.makeStream(); continuation = pair.continuation; return pair.stream
    }
    func feed(_ samples: [Float]) {}
    func stop() async { clock.advance(20); continuation?.finish(); await stopped.append(1) }
    func transcribe(_ pcm16k: [Float]) async throws -> String {
        count += 1; await started.append(count); await gate?.wait()
        clock.advance(30)
        if failure { throw ControllerFailure.final }
        return "private transcript"
    }
}
private actor TimedSink: TextSink {
    let clock: TimingClock
    let gate: ControllerGate?
    let started = ControllerJournal<Int>()
    var count = 0
    var failure = false
    init(_ clock: TimingClock, gate: ControllerGate? = nil) { self.clock = clock; self.gate = gate }
    func setFailure() { failure = true }
    func insert(_ text: String) async throws {
        count += 1; await started.append(count)
        await gate?.wait(); clock.advance(40)
        if failure { throw TextInsertionError.secureInput }
    }
}

@MainActor
final class DictationTimingTests: XCTestCase {
    // Catches missing stage boundaries, use of wall time, and treating sink cleanup as target acceptance.
    func testReleaseReportsOrderedStagesWithoutContent() async throws {
        let clock = TimingClock(), capture = TimedCapture(clock), engine = TimedEngine(clock)
        let controller = DictationController(capture: capture, preview: engine, final: engine, sink: TimedSink(clock), now: clock.now)
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        _ = await state(controller) { if case .shown = $0.phase { true } else { false } }
        await controller.handle(.none)
        let snapshot = await controller.latestTiming
        let timing = try XCTUnwrap(snapshot)
        XCTAssertEqual(timing.session.rawValue, 1)
        XCTAssertEqual(timing.outcome, .inserted)
        XCTAssertEqual(timing.trigger, .release)
        XCTAssertEqual(timing.stages[.mailboxWait], .zero)
        XCTAssertEqual(timing.stages[.captureDrain], .milliseconds(10))
        XCTAssertEqual(timing.stages[.previewDrain], .milliseconds(20))
        XCTAssertEqual(timing.stages[.finalInference], .milliseconds(30))
        XCTAssertEqual(timing.stages[.postProcess], .zero)
        XCTAssertEqual(timing.stages[.insertion], .milliseconds(40))
        XCTAssertEqual(timing.finishToCompletion, .milliseconds(100))
        XCTAssertFalse(timing.diagnosticText.contains("private transcript"))
        XCTAssertTrue(timing.diagnosticText.contains("cleanup"))
        await controller.shutdown()
    }
    // Catches stale operation timing attributed to a subsequent utterance and invented insertion after failure/cancel.
    func testCanceledThenFailedThenShortTapHaveIndependentReports() async throws {
        let clock = TimingClock(), capture = TimedCapture(clock), engine = TimedEngine(clock), gate = ControllerGate()
        let controller = DictationController(capture: capture, preview: engine, final: engine, sink: TimedSink(clock), now: clock.now)
        await engine.configure(gate: gate)
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        await engine.started.waitForCount(1)
        let cancel = Task { await controller.handle(.cancel) }
        _ = await state(controller) { $0.session == nil }
        await gate.release(); await cancel.value
        await controller.handle(.none)
        let canceledSnapshot = await controller.latestTiming
        let canceled = try XCTUnwrap(canceledSnapshot)
        XCTAssertEqual(canceled.outcome, .canceled)
        XCTAssertNil(canceled.stages[.insertion])
        XCTAssertEqual(canceled.stages[.finalInference], .milliseconds(30))
        await engine.configure(failure: true)
        await controller.handle(.pressed); await controller.handle(.released)
        _ = await state(controller) { if case .error = $0.phase { true } else { false } }
        await controller.handle(.none)
        let failedSnapshot = await controller.latestTiming
        let failed = try XCTUnwrap(failedSnapshot)
        XCTAssertEqual(failed.session.rawValue, 2); XCTAssertEqual(failed.outcome, .finalFailed)
        XCTAssertNil(failed.stages[.insertion]); XCTAssertNil(failed.stages[.postProcess])
        await capture.setSamples(3999)
        await controller.handle(.pressed); await controller.handle(.released)
        await controller.handle(.none)
        let tapSnapshot = await controller.latestTiming
        let tap = try XCTUnwrap(tapSnapshot)
        XCTAssertEqual(tap.session.rawValue, 3); XCTAssertEqual(tap.outcome, .shortTap)
        XCTAssertNil(tap.stages[.finalInference]); XCTAssertEqual(tap.finishToCompletion, .milliseconds(30))
        await controller.shutdown()
    }
    // Catches timestamps sampled at dequeue instead of synchronous intake, including mailbox backlog.
    func testReleaseIntakeTimestampSurvivesBlockedMailbox() async throws {
        let clock = TimingClock(), capture = TimedCapture(clock), engine = TimedEngine(clock), gate = ControllerGate()
        await capture.setGate(gate)
        let controller = DictationController(capture: capture, preview: engine, final: engine, sink: TimedSink(clock), now: clock.now)
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        let reconfigure = Task { await controller.configure(capture: capture) }
        _ = await state(controller) { $0.session == nil }
        await engine.stopped.waitForCount(1)
        controller.send(.released); controller.send(.pressed); controller.send(.released)
        clock.advance(70); await gate.release(); await reconfigure.value
        _ = await state(controller) { if case .shown = $0.phase { true } else { false } }
        await controller.handle(.none)
        let snapshot = await controller.latestTiming
        let timing = try XCTUnwrap(snapshot)
        XCTAssertEqual(timing.session.rawValue, 2)
        XCTAssertEqual(timing.stages[.mailboxWait], .milliseconds(80))
        XCTAssertEqual(timing.finishToCompletion, .milliseconds(180))
        await controller.shutdown()
    }
    // Catches completed session data leaking into a queued utterance and completion before sink cleanup.
    func testQueuedSessionHasItsOwnReleaseAndInsertionFailureTiming() async throws {
        let clock = TimingClock(), capture = TimedCapture(clock), engine = TimedEngine(clock), gate = ControllerGate()
        let sink = TimedSink(clock, gate: gate)
        let controller = DictationController(capture: capture, preview: engine, final: engine, sink: sink, now: clock.now)
        await controller.setModelReadiness(.ready); await controller.handle(.pressed); await controller.handle(.released)
        await sink.started.waitForCount(1)
        await controller.handle(.pressed)
        let pending = await controller.latestTiming
        XCTAssertNil(pending)
        await gate.release(); await capture.ready.waitForCount(2); await controller.handle(.none)
        let firstSnapshot = await controller.latestTiming
        let first = try XCTUnwrap(firstSnapshot)
        XCTAssertEqual(first.session.rawValue, 1); XCTAssertEqual(first.finishToCompletion, .milliseconds(100))
        clock.advance(200)
        await sink.setFailure(); await controller.handle(.released)
        _ = await state(controller) { if case .error = $0.phase { true } else { false } }
        await controller.handle(.none)
        let secondSnapshot = await controller.latestTiming
        let second = try XCTUnwrap(secondSnapshot)
        XCTAssertEqual(second.session.rawValue, 2); XCTAssertEqual(second.outcome, .insertionFailed)
        XCTAssertEqual(second.finishToCompletion, .milliseconds(100))
        XCTAssertEqual(second.stages[.insertion], .milliseconds(40))
        await controller.shutdown()
    }
    // Catches a release of the still-held capped key overwriting the automatic finish origin.
    func testAudioCapKeepsItsTriggerWhenPhysicalReleaseArrivesDuringInsertion() async throws {
        let clock = TimingClock(), capture = TimedCapture(clock), engine = TimedEngine(clock), gate = ControllerGate()
        let sink = TimedSink(clock, gate: gate)
        let controller = DictationController(capture: capture, preview: engine, final: engine, sink: sink, now: clock.now)
        await controller.setModelReadiness(.ready); await controller.handle(.pressed)
        await capture.ready.waitForCount(1); await capture.emit(1_920_000)
        await sink.started.waitForCount(1); await controller.handle(.released)
        await gate.release()
        _ = await state(controller) { if case .shown = $0.phase { true } else { false } }
        await controller.handle(.none)
        let snapshot = await controller.latestTiming
        let timing = try XCTUnwrap(snapshot)
        XCTAssertEqual(timing.trigger, .audioCap); XCTAssertEqual(timing.outcome, .inserted)
        XCTAssertNil(timing.stages[.mailboxWait])
        XCTAssertEqual(timing.finishToCompletion, .milliseconds(100))
        await controller.shutdown()
    }
    private func state(_ controller: DictationController, matching: @Sendable (DictationState) -> Bool) async -> DictationState? {
        for await value in await controller.states() { if matching(value) { return value } }
        return nil
    }
}
