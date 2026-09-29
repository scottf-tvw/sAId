@testable import SaidEngine
import Foundation
import Synchronization
import XCTest
@testable import sAId

private enum ProbeError: Error, Equatable { case failed }
private final class RuntimeProbe: Sendable {
    struct State: Sendable {
        var created = 0; var stopped = 0; var released = 0; var loaded = 0
        var failStart = false; var failFeed = false; var failStop = false; var callbackFailure = false
        var terms: [String] = []
    }
    let state = Mutex(State())
}
private final class FakeRuntime: MoonshineRuntime {
    let probe: RuntimeProbe
    init(_ probe: RuntimeProbe) { self.probe = probe; probe.state.withLock { $0.loaded += 1 } }
    func setKeyterms(_ terms: [String]) throws { probe.state.withLock { $0.terms = terms } }
    func transcribeWithoutStreaming(audioData: [Float], sampleRate: Int32, flags: UInt32) throws -> [String] {
        throw ProbeError.failed // Preview-only tests never request final inference.
    }
    func makeStream() throws -> any PreviewRuntimeStream {
        probe.state.withLock { $0.created += 1 }; return FakeStream(probe)
    }
}
private final class FakeStream: PreviewRuntimeStream {
    let probe: RuntimeProbe
    var events: [NativePreviewEvent] = []
    init(_ probe: RuntimeProbe) { self.probe = probe }
    deinit { probe.state.withLock { $0.released += 1 } }
    func start() throws { if probe.state.withLock({ $0.failStart }) { throw ProbeError.failed } }
    func feed(_ samples: [Float]) throws {
        if probe.state.withLock({ $0.failFeed }) { throw ProbeError.failed }
        events += [.line(id: 20, text: "hello", complete: false), .line(id: 3, text: "world", complete: false), .line(id: 20, text: "Hello", complete: true)]
    }
    func stop() throws {
        probe.state.withLock { $0.stopped += 1 }
        if probe.state.withLock({ $0.failStop }) { throw ProbeError.failed }
        events.append(.line(id: 3, text: "world!", complete: true))
        if probe.state.withLock({ $0.callbackFailure }) { events.append(.failure(ProbeError.failed)) }
    }
    func takeEvents() -> [NativePreviewEvent] { defer { events = [] }; return events }
}

@MainActor
final class MoonshinePreviewEngineTests: XCTestCase {
    private func engine(_ probe: RuntimeProbe) -> MoonshineEngine { MoonshineEngine(runtimeFactory: { _ in FakeRuntime(probe) }) }
    private func collect(_ stream: AsyncThrowingStream<PreviewLine, Error>) async throws -> [PreviewLine] {
        var result: [PreviewLine] = []; for try await line in stream { result.append(line) }; return result
    }
    func testFreshSessionsReplaceIDsInFirstSeenOrderAndRetainModel() async throws {
        let probe = RuntimeProbe(), engine = engine(probe)
        try await engine.load(progress: nil)
        for _ in 0..<2 {
            let stream = try await engine.start()
            try await engine.feed([0]); await engine.stop(); await engine.stop()
            let lines = try await collect(stream)
            XCTAssertEqual(lines.map(\.text), ["hello", "hello world", "Hello world", "Hello world!"])
            XCTAssertEqual(lines.map(\.isFinal), [false, false, false, true])
        }
        probe.state.withLock { XCTAssertEqual($0.created, 2); XCTAssertEqual($0.stopped, 2); XCTAssertEqual($0.released, 2); XCTAssertEqual($0.loaded, 1) }
    }
    func testStartFailureAndFeedFailureAllowLaterRecovery() async throws {
        let probe = RuntimeProbe(), engine = engine(probe)
        try await engine.load(progress: nil)
        probe.state.withLock { $0.failStart = true }
        do { _ = try await engine.start(); XCTFail("Expected start failure") } catch {}
        probe.state.withLock { $0.failStart = false; $0.failFeed = true }
        let failed = try await engine.start()
        do { try await engine.feed([0]); XCTFail("Expected feed failure") } catch {}
        do { _ = try await collect(failed); XCTFail("Stream must report feed failure") } catch {}
        probe.state.withLock { $0.failFeed = false }
        let good = try await engine.start(); try await engine.feed([0]); await engine.stop()
        let lines = try await collect(good); XCTAssertEqual(lines.last?.text, "Hello world!")
        probe.state.withLock { XCTAssertEqual($0.released, 3); XCTAssertEqual($0.loaded, 1) }
    }
    func testThrownAndCallbackStopFailuresReachConsumerBeforeFinish() async throws {
        for callback in [false, true] {
            let probe = RuntimeProbe(), engine = engine(probe)
            try await engine.load(progress: nil)
            probe.state.withLock { $0.failStop = !callback; $0.callbackFailure = callback }
            let stream = try await engine.start(); try await engine.feed([0]); await engine.stop(); await engine.stop()
            do { _ = try await collect(stream); XCTFail("Expected stop error") } catch { XCTAssertEqual(error as? ProbeError, .failed) }
            probe.state.withLock { XCTAssertEqual($0.stopped, 1); XCTAssertEqual($0.released, 1) }
        }
    }
    func testKeytermsSanitizedBeforeLoadAndCanBeCleared() async throws {
        let probe = RuntimeProbe(), engine = engine(probe)
        try await engine.setKeyterms([" Ceph ", "", "Ceph", "bad,term", " hello\nworld ", "bad\0term"])
        try await engine.load(progress: nil)
        probe.state.withLock { XCTAssertEqual($0.terms, ["Ceph", "hello world"]) }
        try await engine.setKeyterms([])
        probe.state.withLock { XCTAssertEqual($0.terms, []) }
    }

    func testOfflineMissingModelFailsWithoutDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MoonshineEngine(modelRoot: root)
        do { try await engine.load(progress: nil, downloadIfMissing: false); XCTFail("Expected missing cache") }
        catch { XCTAssertEqual(error as? ModelCacheError, .incomplete) }
    }

    func testLoadFailureCanRetryAndRunsOffMainThread() async throws {
        let probe = RuntimeProbe(), calls = Mutex(0)
        let engine = MoonshineEngine(runtimeFactory: { _ in
            XCTAssertFalse(Thread.isMainThread)
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw ProbeError.failed }
            return FakeRuntime(probe)
        })
        do { try await engine.load(progress: nil); XCTFail("Expected load failure") } catch {}
        try await engine.load(progress: nil)
        try await engine.load(progress: nil)
        XCTAssertEqual(calls.withLock { $0 }, 2)
        let stream = try await engine.start(); try await engine.feed([0]); await engine.stop()
        let lines = try await collect(stream); XCTAssertEqual(lines.last?.text, "Hello world!")
    }

    func testConsumerCancellationReleasesSessionAndAllowsRestart() async throws {
        let probe = RuntimeProbe(), engine = engine(probe)
        try await engine.load(progress: nil)
        let stream = try await engine.start()
        let consumer = Task { try await collect(stream) }
        consumer.cancel()
        _ = try? await consumer.value
        for _ in 0..<10_000 {
            if probe.state.withLock({ $0.released == 1 }) { break }
            await Task.yield()
        }
        XCTAssertEqual(probe.state.withLock { $0.released }, 1)
        let next = try await engine.start(); try await engine.feed([0]); await engine.stop()
        let result = try await collect(next); XCTAssertEqual(result.last?.text, "Hello world!")
        XCTAssertEqual(probe.state.withLock { $0.stopped }, 2)
    }


    func testOldConsumerCancellationCannotStopNewSession() async throws {
        let probe = RuntimeProbe(), engine = engine(probe)
        try await engine.load(progress: nil)
        let old = try await engine.start(); await engine.stop()
        let current = try await engine.start()
        let oldConsumer = Task { try await collect(old) }
        oldConsumer.cancel(); _ = try? await oldConsumer.value
        for _ in 0..<20 { await Task.yield() }
        try await engine.feed([0]); await engine.stop()
        let result = try await collect(current)
        XCTAssertEqual(result.last?.text, "Hello world!")
        XCTAssertEqual(probe.state.withLock { $0.stopped }, 2)
    }


    func testFeedWithoutSessionDoesNotReportResidentModelUnloaded() async throws {
        let probe = RuntimeProbe(), engine = engine(probe)
        try await engine.load(progress: nil)
        let stream = try await engine.start(); await engine.stop(); _ = try await collect(stream)
        do { try await engine.feed([0]); XCTFail("Expected missing session") }
        catch {
            guard case MoonshineEngineError.notStreaming = error else {
                XCTFail("Stopping preview must not report the resident model as unloaded"); return
            }
        }
    }

    func testUnloadedAndOverlappingStartsAreRejected() async throws {
        let probe = RuntimeProbe(), engine = engine(probe)
        do { _ = try await engine.start(); XCTFail("Expected unloaded failure") } catch {}
        try await engine.load(progress: nil)
        let first = try await engine.start()
        do { _ = try await engine.start(); XCTFail("Expected overlap rejection") } catch {}
        await engine.stop(); _ = try await collect(first)
    }
}
