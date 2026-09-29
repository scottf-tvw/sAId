public struct PreviewLine: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

public protocol FinalTranscriber: Sendable {
    /// Whole-utterance input: 16 kHz mono Float32 samples in -1...1.
    func transcribe(_ pcm16k: [Float]) async throws -> String
}

public protocol PreviewTranscriber: AnyObject, Sendable {
    /// Start creates a fresh ordered stream for this session. Previous streams must
    /// finish on stop; cancelling an old consumer must not terminate a later session.
    func start() async throws -> AsyncThrowingStream<PreviewLine, Error>
    /// Input: 16 kHz mono Float32 samples in -1...1, fed in capture order.
    func feed(_ pcm16k: [Float]) async throws
    /// Finish the current session's stream, surfacing native stop errors through it.
    /// Safe to repeat after a failure; the resident model remains loaded.
    func stop() async
}
