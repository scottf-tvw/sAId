import Foundation
import MoonshineVoice
import Synchronization
import XCTest
@testable import sAId

private enum FinalProbeError: Error, Equatable { case failed }

/// Blocks only fake synchronous native work; the test resumes it after observing entry.
private final class NativeCallBarrier: Sendable {
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    func block() {
        entered.continuation.yield(())
        release.wait()
    }
}

private final class FinalRuntimeProbe: Sendable {
    struct State: Sendable {
        var loaded = 0
        var calls: [String] = []
        var audio: [[Float]] = []
        var rates: [Int32] = []
        var flags: [UInt32] = []
        var result = ["Final first.", "", "Second line."]
        var failFinal = false
        var failStop = false
        var nativeActive = false
        var overlaps = 0
        var barrier: NativeCallBarrier?
    }
    let state = Mutex(State())
}

private final class FinalFakeRuntime: MoonshineRuntime {
    let probe: FinalRuntimeProbe
    init(_ probe: FinalRuntimeProbe) {
        self.probe = probe
        probe.state.withLock { $0.loaded += 1 }
    }
    func setKeyterms(_ terms: [String]) throws {}
    func makeStream() throws -> any PreviewRuntimeStream { FinalFakeStream(probe) }
    func transcribeWithoutStreaming(audioData: [Float], sampleRate: Int32, flags: UInt32) throws -> [String] {
        let barrier = probe.state.withLock {
            if $0.nativeActive { $0.overlaps += 1 }
            $0.nativeActive = true
            $0.calls.append("final")
            $0.audio.append(audioData); $0.rates.append(sampleRate); $0.flags.append(flags)
            return $0.barrier
        }
        defer { probe.state.withLock { $0.nativeActive = false } }
        barrier?.block()
        return try probe.state.withLock {
            if $0.failFinal { throw FinalProbeError.failed }
            return $0.result
        }
    }
}

private final class FinalFakeStream: PreviewRuntimeStream {
    let probe: FinalRuntimeProbe
    var events: [NativePreviewEvent] = []
    init(_ probe: FinalRuntimeProbe) { self.probe = probe }
    func start() throws {
        probe.state.withLock {
            if $0.nativeActive { $0.overlaps += 1 }
            $0.calls.append("start")
        }
    }
    func feed(_ samples: [Float]) throws {
        probe.state.withLock { $0.calls.append("feed") }
        events.append(.line(id: 7, text: "Display-only preview", complete: false))
    }
    func stop() throws {
        try probe.state.withLock {
            $0.calls.append("stop")
            if $0.failStop { throw FinalProbeError.failed }
        }
        events.append(.line(id: 7, text: "Display-only preview.", complete: true))
    }
    func takeEvents() -> [NativePreviewEvent] { defer { events = [] }; return events }
}

@MainActor
final class MoonshineFinalEngineTests: XCTestCase {
    private func engine(_ probe: FinalRuntimeProbe) -> MoonshineEngine {
        MoonshineEngine(runtimeFactory: { _ in FinalFakeRuntime(probe) })
    }
    private func drain(_ stream: AsyncThrowingStream<PreviewLine, Error>) async throws -> [PreviewLine] {
        var result: [PreviewLine] = []
        for try await line in stream { result.append(line) }
        return result
    }

    func testNotLoadedRejectsSpeechAndEmptyInput() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe)
        let final: any FinalTranscriber = engine
        for samples: [Float] in [[0.25], []] {
            do { _ = try await final.transcribe(samples); XCTFail("Expected not loaded") }
            catch { guard case MoonshineEngineError.notLoaded = error else { return XCTFail("Unexpected error: \(error)") } }
        }
        XCTAssertTrue(probe.state.withLock { $0.audio.isEmpty })
    }

    func testEmptyAndExactSilenceSkipNativeButQuietSpeechDoesNot() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe)
        let final: any FinalTranscriber = engine
        try await engine.load()
        for samples: [Float] in [[], [0, -0.0, 0]] {
            let text = try await final.transcribe(samples)
            XCTAssertEqual(text, "")
        }
        XCTAssertTrue(probe.state.withLock { $0.audio.isEmpty })
        let text = try await final.transcribe([Float.leastNonzeroMagnitude])
        XCTAssertEqual(text, "Final first. Second line.")
        XCTAssertEqual(probe.state.withLock { $0.audio }, [[Float.leastNonzeroMagnitude]])
    }

    func testRejectsNonfiniteAudioBeforeNativeAndAllowsRecovery() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe)
        let final: any FinalTranscriber = engine
        try await engine.load()
        for invalid: Float in [.nan, .infinity, -.infinity] {
            do { _ = try await final.transcribe([0.1, invalid]); XCTFail("Expected invalid audio rejection") }
            catch { XCTAssertTrue(error is MoonshineEngineError) }
        }
        XCTAssertTrue(probe.state.withLock { $0.audio.isEmpty })
        let text = try await final.transcribe([0.1])
        XCTAssertEqual(text, "Final first. Second line.")
    }

    func testFinalRequiresPreviewStopAndRetainsOneModelAcrossNewSessions() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe)
        let final: any FinalTranscriber = engine
        try await engine.load()
        for _ in 0..<2 {
            let stream = try await engine.start()
            try await engine.feed([0.1])
            for samples: [Float] in [[0.1], []] {
                do { _ = try await final.transcribe(samples); XCTFail("Expected active preview rejection") }
                catch { guard case MoonshineEngineError.alreadyStreaming = error else { return XCTFail("Unexpected error: \(error)") } }
            }
            await engine.stop()
            let preview = try await drain(stream)
            XCTAssertEqual(preview.last?.text, "Display-only preview.")
            let text = try await final.transcribe([0.1, -0.2])
            XCTAssertEqual(text, "Final first. Second line.")
        }
        probe.state.withLock {
            XCTAssertEqual($0.loaded, 1)
            XCTAssertEqual($0.calls, ["start", "feed", "stop", "final", "start", "feed", "stop", "final"])
            XCTAssertEqual($0.rates, [16_000, 16_000]); XCTAssertEqual($0.flags, [0, 0])
            XCTAssertEqual($0.audio, [[0.1, -0.2], [0.1, -0.2]])
        }
    }

    func testNativeFailureNeverReturnsPreviewAndModelCanTranscribeAgain() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe)
        let final: any FinalTranscriber = engine
        try await engine.load()
        let stream = try await engine.start()
        try await engine.feed([0.1]); await engine.stop(); _ = try await drain(stream)
        probe.state.withLock { $0.failFinal = true }
        do { _ = try await final.transcribe([0.1]); XCTFail("Expected final failure") }
        catch { XCTAssertEqual(error as? FinalProbeError, .failed) }
        probe.state.withLock { $0.failFinal = false; $0.result = [" second\nline", "FIRST", ""] }
        let text = try await final.transcribe([0.2])
        XCTAssertEqual(text, " second\nline FIRST", "Preserve native line order, casing, and whitespace")
        XCTAssertEqual(probe.state.withLock { $0.loaded }, 1)
    }

    func testFailedPreviewStopStillAllowsFinalThenNewPreview() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe)
        let final: any FinalTranscriber = engine
        try await engine.load()
        probe.state.withLock { $0.failStop = true }
        let failed = try await engine.start(); try await engine.feed([0.1]); await engine.stop()
        do { _ = try await drain(failed); XCTFail("Expected preview failure") }
        catch { XCTAssertEqual(error as? FinalProbeError, .failed) }
        let text = try await final.transcribe([0.1]); XCTAssertEqual(text, "Final first. Second line.")
        probe.state.withLock { $0.failStop = false }
        let next = try await engine.start(); try await engine.feed([0.2]); await engine.stop()
        let nextLines = try await drain(next)
        XCTAssertEqual(nextLines.last?.text, "Display-only preview.")
        XCTAssertEqual(probe.state.withLock { $0.loaded }, 1)
    }

    func testCancellationBeforeCallDoesNotEnterNativeEvenForEmptyInput() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe)
        let final: any FinalTranscriber = engine
        try await engine.load()
        for samples: [Float] in [[0.1], []] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await final.transcribe(samples)
            }
            do { _ = try await task.value; XCTFail("Cancelled request must not return text") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertTrue(probe.state.withLock { $0.audio.isEmpty })
    }

    func testCancellationDuringNativeCallSuppressesLateTextAndAllowsReuse() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe), barrier = NativeCallBarrier()
        let final: any FinalTranscriber = engine
        try await engine.load()
        probe.state.withLock { $0.barrier = barrier }
        let task = Task { try await final.transcribe([0.1]) }
        var entered = barrier.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        task.cancel()
        barrier.release.signal()
        do { _ = try await task.value; XCTFail("Native text completed after cancel must not escape") }
        catch { XCTAssertTrue(error is CancellationError) }
        probe.state.withLock { $0.barrier = nil }
        let text = try await final.transcribe([0.2]); XCTAssertEqual(text, "Final first. Second line.")
        let next = try await engine.start(); await engine.stop(); _ = try await drain(next)
        XCTAssertEqual(probe.state.withLock { $0.loaded }, 1)
    }

    func testNativeFinalSerializesQueuedFinalAndPreviewStart() async throws {
        let probe = FinalRuntimeProbe(), engine = engine(probe), barrier = NativeCallBarrier()
        let final: any FinalTranscriber = engine
        try await engine.load()
        probe.state.withLock { $0.barrier = barrier }
        let first = Task { try await final.transcribe([0.1]) }
        var entered = barrier.entered.stream.makeAsyncIterator(); _ = await entered.next()
        let requested = AsyncStream<Void>.makeStream()
        let next = Task {
            requested.continuation.yield(())
            return try await final.transcribe([0.2])
        }
        var request = requested.stream.makeAsyncIterator(); _ = await request.next()
        probe.state.withLock { $0.barrier = nil }
        barrier.release.signal()
        _ = try await first.value; _ = try await next.value
        let previewBarrier = NativeCallBarrier()
        probe.state.withLock { $0.barrier = previewBarrier }
        let third = Task { try await final.transcribe([0.3]) }
        var thirdEntered = previewBarrier.entered.stream.makeAsyncIterator(); _ = await thirdEntered.next()
        let previewRequested = AsyncStream<Void>.makeStream()
        let preview = Task { previewRequested.continuation.yield(()); return try await engine.start() }
        var previewRequest = previewRequested.stream.makeAsyncIterator(); _ = await previewRequest.next()
        previewBarrier.release.signal()
        _ = try await third.value
        let stream = try await preview.value
        await engine.stop(); _ = try await drain(stream)
        probe.state.withLock {
            XCTAssertEqual($0.overlaps, 0)
            XCTAssertEqual($0.calls, ["final", "final", "final", "start", "stop"])
            XCTAssertEqual($0.audio, [[0.1], [0.2], [0.3]])
        }
    }

    func testOfflineFixturesFinalAfterPreviewAndRepeatedSessionsOnOneModel() async throws {
        guard ProcessInfo.processInfo.environment["SAID_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set SAID_MODEL_TESTS=1 to run offline cached-model contracts")
        }
        let cache = sAId.ModelCache(root: defaultModelRoot, manifest: try .englishMedium())
        guard try cache.isComplete() else { throw XCTSkip("Complete verified cached model unavailable; never download in contracts") }
        let engine = MoonshineEngine()
        let final: any FinalTranscriber = engine
        let loading = Date()
        try await engine.load(downloadIfMissing: false)
        print("FINAL MODEL load including verification: \(Date().timeIntervalSince(loading)) s")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let references = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtures.appendingPathComponent("transcripts.json")))
        var firstResults: [String: String] = [:]
        for repetition in 1...2 {
            for name in references.keys.sorted() {
                let wav = try loadWAVFile(fixtures.appendingPathComponent(name).path)
                XCTAssertEqual(wav.sampleRate, 16_000)
                let stream = try await engine.start()
                for offset in stride(from: 0, to: wav.audioData.count, by: 4800) {
                    try await engine.feed(Array(wav.audioData[offset..<min(offset + 4800, wav.audioData.count)]))
                }
                await engine.stop()
                let previewLines = try await drain(stream)
                let preview = try XCTUnwrap(previewLines.last?.text)
                let begin = Date()
                let text = try await final.transcribe(wav.audioData)
                let elapsed = Date().timeIntervalSince(begin)
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                let reference = try XCTUnwrap(references[name])
                let wer = contractWER(reference: reference, hypothesis: text)
                XCTAssertLessThanOrEqual(wer, 0.5, "Final pipeline regression for \(name): \(text)")
                if let first = firstResults[name] { XCTAssertEqual(text, first, "Repeated final must retain ordered text") }
                else { firstResults[name] = text }
                print("FINAL MODEL repetition \(repetition) \(name): \(text) | WER \(wer) | preview comparison WER \(contractWER(reference: preview, hypothesis: text)) | final wall \(elapsed) s")
            }
        }
    }
}
