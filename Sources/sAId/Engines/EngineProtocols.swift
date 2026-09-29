struct PreviewLine: Sendable, Equatable {
    let text: String
    let isFinal: Bool
}

protocol FinalTranscriber: Sendable {
    /// Whole-utterance input: 16 kHz mono Float32 samples in -1...1.
    func transcribe(_ pcm16k: [Float]) async throws -> String
}

protocol PreviewTranscriber: AnyObject, Sendable {
    /// Start creates a fresh ordered stream for this session. Previous streams must
    /// finish on stop; cancelling an old consumer must not terminate a later session.
    func start() async throws -> AsyncStream<PreviewLine>
    /// Input: 16 kHz mono Float32 samples in -1...1, fed in capture order.
    func feed(_ pcm16k: [Float]) async throws
    /// Finish the current session's stream; safe to repeat after a failure.
    func stop() async
}
