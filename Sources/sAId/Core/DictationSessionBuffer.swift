/// Audio acceptance is independent of preview/inference and the controller's ordered actions.
/// Only this actor appends samples; its preview stream retains the same ordered, trimmed chunks.
actor DictationSessionBuffer {
    static let sampleLimit = 1_920_000
    private(set) var samples: [Float] = []
    private(set) var captureFailure: String?
    private(set) var previewFailure: String?
    private(set) var latestPreview: PreviewLine?
    let previewInput: AsyncStream<[Float]>
    private let previewContinuation: AsyncStream<[Float]>.Continuation

    init() {
        let pair = AsyncStream<[Float]>.makeStream()
        previewInput = pair.stream
        previewContinuation = pair.continuation
    }
    func append(_ chunk: [Float]) -> Bool {
        let remaining = Self.sampleLimit - samples.count
        guard remaining > 0, !chunk.isEmpty else { return false }
        let accepted = Array(chunk.prefix(remaining))
        samples.append(contentsOf: accepted)
        previewContinuation.yield(accepted)
        return true
    }
    var sampleCount: Int { samples.count }
    func finishAudio() { previewContinuation.finish() }
    func captureFailed(_ reason: String) { captureFailure = reason }
    func previewFailed(_ reason: String) { if previewFailure == nil { previewFailure = reason } }
    func preview(_ line: PreviewLine) { latestPreview = line }
}
