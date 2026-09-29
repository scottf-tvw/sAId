import XCTest
@testable import sAId

private actor FakeAudioBackend: AudioCaptureBackend {
    var samples: (@Sendable ([Float]) -> Void)?
    var interruption: (@Sendable (AudioCaptureError) -> Void)?
    var previousInterruption: (@Sendable (AudioCaptureError) -> Void)?
    var previousSamples: (@Sendable ([Float]) -> Void)?
    var starts = 0
    var stops = 0
    var deviceUID: String?
    var fails = false
    var startGate: CheckedContinuation<Void, Never>?
    var holdStart = false

    func start(deviceUID: String, onSamples: @escaping @Sendable ([Float]) -> Void,
               onInterruption: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        starts += 1
        self.deviceUID = deviceUID
        if holdStart { await withCheckedContinuation { startGate = $0 } }
        if fails { throw AudioCaptureError.deviceUnavailable }
        samples = onSamples
        interruption = onInterruption
    }
    func stop() {
        stops += 1; samples?([3])
        previousSamples = samples; previousInterruption = interruption
        samples = nil; interruption = nil
    }
    func emitStaleCallbacks() { previousSamples?([99]); previousInterruption?(.deviceUnavailable) }
    func emit(_ value: [Float]) { samples?(value) }
    func interrupt(_ error: AudioCaptureError) { interruption?(error) }
    func setFailure() { fails = true }
    func suspendStart() { holdStart = true }
    func releaseStart() { startGate?.resume(); startGate = nil }
    func startIsSuspended() -> Bool { startGate != nil }
    func counts() -> (Int, Int) { (starts, stops) }
}

@MainActor
final class AudioCaptureTests: XCTestCase {
    func testStopDrainsAcceptedChunksAndRepeatedStopIsSafe() async throws {
        let backend = FakeAudioBackend()
        let capture = AudioCapture(inputDeviceUID: "selected-uid", backendFactory: { backend })
        let stream = try await capture.start()
        await backend.emit([1]); await backend.emit([2])
        await capture.stop(); await capture.stop()
        var chunks: [[Float]] = []
        for try await chunk in stream { chunks.append(chunk) }
        XCTAssertEqual(chunks, [[1], [2], [3]])
        let counts = await backend.counts()
        XCTAssertEqual(counts.1, 1)
        let uid = await backend.deviceUID
        XCTAssertEqual(uid, "selected-uid")
    }

    func testStartFailureCleansUpAndNextPressCanRecover() async throws {
        let failing = FakeAudioBackend(); await failing.setFailure()
        let healthy = FakeAudioBackend()
        let factory = BackendSequence([failing, healthy])
        let capture = AudioCapture(backendFactory: { factory.next() })
        do { _ = try await capture.start(); XCTFail("Expected start failure") }
        catch { XCTAssertEqual(error as? AudioCaptureError, .deviceUnavailable) }
        let failedCounts = await failing.counts()
        XCTAssertEqual(failedCounts.1, 1)
        let stream = try await capture.start()
        await healthy.emit([7]); await capture.stop()
        var chunks: [[Float]] = []
        for try await chunk in stream { chunks.append(chunk) }
        XCTAssertEqual(chunks, [[7], [3]])
    }

    func testConfigurationWakeAndDeviceLossFinishThenRebuild() async throws {
        for reason in [AudioCaptureError.configurationChanged, .systemWoke, .deviceUnavailable] {
            let old = FakeAudioBackend(); let fresh = FakeAudioBackend()
            let factory = BackendSequence([old, fresh])
            let capture = AudioCapture(backendFactory: { factory.next() })
            let stream = try await capture.start()
            await old.emit([1]); await old.interrupt(reason)
            var chunks: [[Float]] = []
            do { for try await chunk in stream { chunks.append(chunk) }; XCTFail("Expected interruption") }
            catch { XCTAssertEqual(error as? AudioCaptureError, reason) }
            XCTAssertEqual(chunks, [[1]])
            let restarted = try await capture.start()
            await fresh.emit([2]); await capture.stop()
            var newChunks: [[Float]] = []
            for try await chunk in restarted { newChunks.append(chunk) }
            XCTAssertEqual(newChunks, [[2], [3]])
        }
    }

    func testStopDuringSuspendedStartDoesNotOrphanBackend() async throws {
        let backend = FakeAudioBackend(); await backend.suspendStart()
        let capture = AudioCapture(backendFactory: { backend })
        let starting = Task { try await capture.start() }
        for _ in 0..<10_000 {
            if await backend.startIsSuspended() { break }
            await Task.yield()
        }
        guard await backend.startIsSuspended() else { XCTFail("Start did not reach its gate"); return }
        let stopping = Task { await capture.stop() }
        await Task.yield()
        await backend.releaseStart()
        let stream = try await starting.value
        await stopping.value
        var chunks: [[Float]] = []
        for try await chunk in stream { chunks.append(chunk) }
        XCTAssertEqual(chunks, [[3]])
        let counts = await backend.counts()
        XCTAssertEqual(counts.1, 1)
    }

    func testOverlappingStartIsRejectedAndEachRestartGetsAFreshStream() async throws {
        let backend = FakeAudioBackend()
        let capture = AudioCapture(backendFactory: { backend })
        let first = try await capture.start()
        do { _ = try await capture.start(); XCTFail("Expected overlapping start rejection") }
        catch { XCTAssertEqual(error as? AudioCaptureError, .alreadyRunning) }
        await backend.emit([1]); await capture.stop()
        let second = try await capture.start()
        await backend.emit([2]); await capture.stop()
        var firstChunks: [[Float]] = []
        var secondChunks: [[Float]] = []
        for try await chunk in first { firstChunks.append(chunk) }
        for try await chunk in second { secondChunks.append(chunk) }
        XCTAssertEqual(firstChunks, [[1], [3]])
        XCTAssertEqual(secondChunks, [[2], [3]])
    }

    func testCancellationDuringStartQuiescesBackend() async throws {
        let backend = FakeAudioBackend(); await backend.suspendStart()
        let capture = AudioCapture(backendFactory: { backend })
        let starting = Task { try await capture.start() }
        for _ in 0..<10_000 {
            if await backend.startIsSuspended() { break }
            await Task.yield()
        }
        guard await backend.startIsSuspended() else { XCTFail("Start did not reach its gate"); return }
        starting.cancel()
        await backend.releaseStart()
        do { _ = try await starting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let counts = await backend.counts()
        XCTAssertEqual(counts.1, 1)
        await capture.stop()
    }


    func testLateCallbacksFromOldSessionCannotTerminateRestartedCapture() async throws {
        let old = FakeAudioBackend(); let fresh = FakeAudioBackend()
        let factory = BackendSequence([old, fresh])
        let capture = AudioCapture(backendFactory: { factory.next() })
        let first = try await capture.start()
        await capture.stop()
        let second = try await capture.start()
        await old.emitStaleCallbacks()
        for _ in 0..<10 { await Task.yield() }
        await fresh.emit([2]); await capture.stop()
        var firstChunks: [[Float]] = []
        var secondChunks: [[Float]] = []
        for try await chunk in first { firstChunks.append(chunk) }
        for try await chunk in second { secondChunks.append(chunk) }
        XCTAssertEqual(firstChunks, [[3]])
        XCTAssertEqual(secondChunks, [[2], [3]])
    }

}

import Synchronization
private final class BackendSequence: Sendable {
    private let remaining: Mutex<[FakeAudioBackend]>
    init(_ backends: [FakeAudioBackend]) { remaining = Mutex(backends) }
    func next() -> any AudioCaptureBackend { remaining.withLock { $0.removeFirst() } }
}
