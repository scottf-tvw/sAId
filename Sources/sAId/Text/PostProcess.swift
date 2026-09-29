/// Immutable configuration safely passed from settings to the dictation actor.
struct PostProcess: Sendable {
    let corrections: [Correction]
    let fillers: [String]
    let trailingSpace: Bool

    init(corrections: [Correction] = Correction.defaults,
         fillers: [String] = FillerRemoval.defaults,
         trailingSpace: Bool = false) {
        self.corrections = corrections
        self.fillers = fillers
        self.trailingSpace = trailingSpace
    }

    func apply(_ text: String) -> String {
        var result = ProtectedText(text)
        result.correct(corrections)
        FillerRemoval.apply(to: &result, fillers: fillers)
        FillerRemoval.clean(&result)
        result.capitalizeFirstWord()
        let output = result.string
        return output.isEmpty ? "" : output + (trailingSpace ? " " : "")
    }
}
