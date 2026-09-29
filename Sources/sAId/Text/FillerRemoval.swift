// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
import Foundation

enum FillerRemoval {
    static let defaults = ["um", "uh", "er", "hmm", "you know"]

    static func apply(to text: inout ProtectedText, fillers: [String]) {
        let original = text.string
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            guard let word = ProtectedText.wordPattern(filler, filler: true) else { continue }
            // Remove paired commas around a parenthetical filler together.
            text.rewrite(#",\s*"# + word + #"\s*,"#) { _ in " " }
            // A final filler owns its preceding comma, but the sentence keeps its terminator.
            text.rewrite(#",\s*"# + word + #"(?=\s*[.!?]+\s*$)"#) { _ in "" }
            text.rewrite(word + #"(?:\s*,)?"#) { _ in "" }
        }
        if text.string != original {
            // A filler-only utterance has no sentence whose punctuation needs retaining.
            text.rewrite(#"^[\s.,!?;:]+$"#) { _ in "" }
        }
    }

    static func clean(_ text: inout ProtectedText) {
        text.rewrite(#"\s+([.,!?;:])"#) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        text.rewrite(#"\s+"#) { _ in " " }
        text.rewrite(#"^[\s,.;:]+|\s+$"#) { _ in "" }
    }
}
