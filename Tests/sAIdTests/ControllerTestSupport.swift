import Foundation
@testable import sAId

actor ControllerGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}
actor ControllerJournal<Value: Sendable> {
    private(set) var values: [Value] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func append(_ value: Value) {
        values.append(value)
        let ready = waiters.filter { values.count >= $0.0 }
        waiters.removeAll { values.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func waitForCount(_ count: Int) async {
        if values.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
}
enum ControllerFailure: Error { case capture, preview, final }
actor ControllerCapture: CaptureSource {
    var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    var finalChunks: [[Float]] = []
    var failStart = false
    let starts = ControllerJournal<Int>()
    let ready = ControllerJournal<Int>()
    let stops = ControllerJournal<Int>()
    var cancellationSignal: (@Sendable () -> Void)?
    var count = 0
    var startGate: ControllerGate?
    func configure(chunks: [[Float]] = [], fail: Bool = false, gate: ControllerGate? = nil, cancelled: (@Sendable () -> Void)? = nil) {
        finalChunks = chunks; failStart = fail; startGate = gate; cancellationSignal = cancelled
    }
    func start() async throws -> AsyncThrowingStream<[Float], Error> {
        count += 1; await starts.append(count)
        let cancellationSignal = cancellationSignal
        await withTaskCancellationHandler {
            await startGate?.wait()
        } onCancel: { cancellationSignal?() }
        if failStart { throw ControllerFailure.capture }
        let pair = AsyncThrowingStream<[Float], Error>.makeStream()
        continuation = pair.continuation
        await ready.append(count)
        return pair.stream
    }
    func emit(_ samples: [Float]) { continuation?.yield(samples) }
    func fail() { continuation?.finish(throwing: ControllerFailure.capture) }
    func stop() async {
        for chunk in finalChunks { continuation?.yield(chunk) }
        finalChunks = []
        continuation?.finish(); continuation = nil
        await stops.append(count)
    }
}
actor ControllerEngine: PreviewTranscriber, FinalTranscriber {
    var continuation: AsyncThrowingStream<PreviewLine, Error>.Continuation?
    var final = "final words"
    var failFinal = false
    var previewFailure: String?
    var finalGate: ControllerGate?
    var feedGate: ControllerGate?
    let finalInputs = ControllerJournal<[Float]>()
    let feeds = ControllerJournal<[Float]>()
    let starts = ControllerJournal<Int>()
    var count = 0
    func configure(final: String = "final words", failFinal: Bool = false, previewFailure: String? = nil,
                   finalGate: ControllerGate? = nil, feedGate: ControllerGate? = nil) {
        self.final = final; self.failFinal = failFinal; self.previewFailure = previewFailure
        self.finalGate = finalGate; self.feedGate = feedGate
    }
    func start() async throws -> AsyncThrowingStream<PreviewLine, Error> {
        count += 1; await starts.append(count)
        if previewFailure == "start" { throw ControllerFailure.preview }
        let pair = AsyncThrowingStream<PreviewLine, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func feed(_ samples: [Float]) async throws {
        await feeds.append(samples); await feedGate?.wait()
        if previewFailure == "feed" {
            continuation?.finish(throwing: ControllerFailure.preview)
            throw ControllerFailure.preview
        }
        continuation?.yield(PreviewLine(text: "preview words", isFinal: false))
        if previewFailure == "event" { continuation?.finish(throwing: ControllerFailure.preview) }
    }
    func stop() {
        continuation?.finish(throwing: previewFailure == "stop" ? ControllerFailure.preview : nil)
        continuation = nil
    }
    func transcribe(_ pcm16k: [Float]) async throws -> String {
        await finalInputs.append(pcm16k); await finalGate?.wait()
        if failFinal { throw ControllerFailure.final }
        return final
    }
}
actor ControllerSink: TextSink {
    let inputs = ControllerJournal<String>()
    let cleaned = ControllerJournal<String>()
    var gate: ControllerGate?
    var failure: TextInsertionError?
    func configure(gate: ControllerGate? = nil, failure: TextInsertionError? = nil) {
        self.gate = gate; self.failure = failure
    }
    func insert(_ text: String) async throws {
        await inputs.append(text); await gate?.wait()
        await cleaned.append(text)
        try Task.checkCancellation()
        if let failure { throw failure }
    }
}
struct ControllerRig: Sendable {
    let capture = ControllerCapture()
    let engine = ControllerEngine()
    let sink = ControllerSink()
    let history = ControllerJournal<DictationHistoryEntry>()
    let logs = ControllerJournal<String>()
    func controller() -> DictationController {
        DictationController(capture: capture, preview: engine, final: engine, sink: sink,
                            record: { await history.append($0) }, log: { await logs.append($0) })
    }
}

actor ControllerClock {
    let requests = ControllerJournal<Duration>()
    private var next = 0
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    func delay(_ duration: Duration) async throws {
        let id = next; next += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else {
                    waiting[id] = continuation
                    Task { await requests.append(duration) }
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func fire(_ id: Int) { waiting.removeValue(forKey: id)?.resume() }
    private func cancel(_ id: Int) { waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
