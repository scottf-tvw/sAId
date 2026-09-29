import Foundation
import MoonshineVoice

public enum MoonshineEngineError: Error { case notLoaded, notStreaming, alreadyStreaming, loading, invalidAudio }

enum NativePreviewEvent: Sendable {
    case line(id: UInt64, text: String, complete: Bool)
    case failure(any Error)
}

/// Synchronous seam. Only the owning engine actor calls these methods; there are no native
/// objects or callbacks crossing executors. Preview and final use the same resident native model.
protocol MoonshineRuntime: AnyObject {
    func makeStream() throws -> any PreviewRuntimeStream
    func setKeyterms(_ terms: [String]) throws
    func transcribeWithoutStreaming(audioData: [Float], sampleRate: Int32, flags: UInt32) throws -> [String]
}
protocol PreviewRuntimeStream: AnyObject {
    func start() throws
    func feed(_ samples: [Float]) throws
    func stop() throws
    func takeEvents() -> [NativePreviewEvent]
}

public actor MoonshineEngine: PreviewTranscriber, FinalTranscriber {
    private let modelRoot: URL
    private let runtimeFactory: @Sendable (URL) throws -> any MoonshineRuntime
    private let needsCache: Bool
    private var runtime: (any MoonshineRuntime)?
    private var nativeStream: (any PreviewRuntimeStream)?
    private var continuation: AsyncThrowingStream<PreviewLine, Error>.Continuation?
    private var session: UInt64 = 0
    private var order: [UInt64] = []
    private var lines: [UInt64: (String, Bool)] = [:]
    private var keyterms: [String] = []
    private var loading = false

    public init(modelRoot: URL = defaultModelRoot) {
        self.modelRoot = modelRoot; self.needsCache = true
        self.runtimeFactory = { try NativeMoonshineRuntime(root: $0) }
    }
    /// The factory is invoked on this actor; deterministic unit tests need neither disk assets nor native inference.
    init(runtimeFactory: @escaping @Sendable (URL) throws -> any MoonshineRuntime) {
        self.modelRoot = defaultModelRoot; self.runtimeFactory = runtimeFactory; self.needsCache = false
    }

    public func load(progress: ModelProgress? = nil, downloadIfMissing: Bool = true) async throws {
        if runtime != nil { return }
        guard !loading else { throw MoonshineEngineError.loading }
        loading = true
        defer { loading = false }
        if needsCache {
            let cache = ModelCache(root: modelRoot, manifest: try .englishMedium())
            if downloadIfMissing { try await cache.ensurePresent(progress: progress) }
            else if try !cache.isComplete() { throw ModelCacheError.incomplete }
        }
        try Task.checkCancellation()
        progress?(1, "Loading Moonshine")
        let loaded = try runtimeFactory(modelRoot)
        try loaded.setKeyterms(keyterms)
        try Task.checkCancellation()
        runtime = loaded
        progress?(1, "Ready")
    }

    /// Only for user-confirmed reset or quit, after the controller is quiescent
    /// and the load task has finished. Actor isolation waits for synchronous inference.
    /// Explicitly drop native ownership even if an old controller still retains this actor.
    public func releaseForExplicitReset() throws {
        guard !loading else { throw MoonshineEngineError.loading }
        guard nativeStream == nil else { throw MoonshineEngineError.alreadyStreaming }
        continuation?.finish(); continuation = nil
        runtime = nil
        order.removeAll(); lines.removeAll()
    }

    public func setKeyterms(_ terms: [String]) throws {
        var seen = Set<String>()
        let cleaned = terms.compactMap { raw -> String? in
            guard !raw.contains(","), !raw.contains("\0") else { return nil }
            let term = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !term.isEmpty, !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(term).inserted else { return nil }
            return term
        }
        try runtime?.setKeyterms(cleaned)
        keyterms = cleaned
    }

    /// Whole-utterance inference shares the resident runtime and never yields actor ownership.
    /// The native call is synchronous and cannot be preempted. Cancellation is checked at its
    /// boundaries so a result completed after cancellation cannot reach the caller for insertion.
    public func transcribe(_ pcm16k: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard let runtime else { throw MoonshineEngineError.notLoaded }
        guard nativeStream == nil else { throw MoonshineEngineError.alreadyStreaming }
        guard pcm16k.allSatisfy({ $0.isFinite }) else { throw MoonshineEngineError.invalidAudio }
        guard pcm16k.contains(where: { $0 != 0 }) else { return "" }
        try Task.checkCancellation()
        let lines = try runtime.transcribeWithoutStreaming(audioData: pcm16k, sampleRate: 16_000, flags: 0)
        try Task.checkCancellation()
        return lines.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func start() throws -> AsyncThrowingStream<PreviewLine, Error> {
        try Task.checkCancellation()
        guard let runtime else { throw MoonshineEngineError.notLoaded }
        guard nativeStream == nil else { throw MoonshineEngineError.alreadyStreaming }
        let native = try runtime.makeStream()
        session &+= 1
        let id = session
        let pair = AsyncThrowingStream<PreviewLine, Error>.makeStream()
        continuation = pair.continuation
        nativeStream = native
        order = []; lines = [:]
        pair.continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.cancelSession(id) } }
        }
        do {
            try native.start()
            try publish(native.takeEvents())
            return pair.stream
        } catch {
            finish(error)
            throw error
        }
    }

    public func feed(_ pcm16k: [Float]) throws {
        guard let native = nativeStream else {
            throw runtime == nil ? MoonshineEngineError.notLoaded : MoonshineEngineError.notStreaming
        }
        do {
            try Task.checkCancellation()
            try native.feed(pcm16k)
            try publish(native.takeEvents())
        } catch {
            // End native work once, preserve the original failure, and retain the resident model.
            try? native.stop()
            _ = native.takeEvents()
            finish(error)
            throw error
        }
    }

    public func stop() {
        guard let native = nativeStream else { return }
        do {
            try native.stop()
            // Native stop catches final-update failures and emits TranscriptError synchronously.
            // Drain here, before finish; never enqueue callback Tasks that can race completion.
            try publish(native.takeEvents())
            finish(nil)
        } catch { finish(error) }
    }

    private func cancelSession(_ id: UInt64) {
        guard id == session, let native = nativeStream else { return }
        try? native.stop()
        _ = native.takeEvents()
        finish(CancellationError())
    }
    private func publish(_ events: [NativePreviewEvent]) throws {
        for event in events {
            switch event {
            case .failure(let error): throw error
            case .line(let id, let text, let complete):
                if lines[id] == nil { order.append(id) }
                lines[id] = (text, complete)
                let text = order.compactMap { lines[$0]?.0 }.filter { !$0.isEmpty }.joined(separator: " ")
                continuation?.yield(PreviewLine(text: text, isFinal: order.allSatisfy { lines[$0]?.1 == true }))
            }
        }
    }
    private func finish(_ error: (any Error)?) {
        continuation?.finish(throwing: error)
        continuation = nil
        // Upstream close() is not idempotent and deinit calls it. ARC is the sole close owner.
        nativeStream = nil
        order = []; lines = [:]
    }
}

private final class NativeMoonshineRuntime: MoonshineRuntime {
    let transcriber: Transcriber
    init(root: URL) throws { transcriber = try Transcriber(modelPath: root.path, modelArch: .mediumStreaming) }
    func setKeyterms(_ terms: [String]) throws { try transcriber.setKeyterms(terms) }
    func transcribeWithoutStreaming(audioData: [Float], sampleRate: Int32, flags: UInt32) throws -> [String] {
        try transcriber.transcribeWithoutStreaming(audioData: audioData, sampleRate: sampleRate, flags: flags).lines.map(\.text)
    }
    func makeStream() throws -> any PreviewRuntimeStream {
        NativeMoonshineStream(stream: try transcriber.createStream(updateInterval: 0.3))
    }
}

private final class NativeEventCollector {
    var events: [NativePreviewEvent] = []
}
private final class NativeMoonshineStream: PreviewRuntimeStream {
    let stream: MoonshineVoice.Stream
    let collector = NativeEventCollector()
    init(stream: MoonshineVoice.Stream) {
        self.stream = stream
        stream.addListener { [collector] event in
            if let error = event as? TranscriptError { collector.events.append(.failure(error.error)); return }
            if event is LineStarted || event is LineTextChanged || event is LineCompleted {
                let line = event.line
                collector.events.append(.line(id: line.lineId, text: line.text, complete: line.isComplete))
            }
        }
    }
    func start() throws { try stream.start() }
    func feed(_ samples: [Float]) throws { try stream.addAudio(samples, sampleRate: 16_000) }
    func stop() throws { try stream.stop() }
    func takeEvents() -> [NativePreviewEvent] { defer { collector.events = [] }; return collector.events }
}
