// REFERENCE ONLY — not compiled.
// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
// Extracted from TVWIT/hAIvd-Assist commit 5b0f9a7, sidecar/Sources/HaiveSpeechSidecar/main.swift,
// region "Filler word removal" (lines 2406-2471). Adapt into sAId modules; keep this notice on derived files.

// MARK: - Filler word removal
//
// Deterministic regex pass that strips standalone non-word fillers
// ("um", "uh", "ah", "er", "erm", "hmm") and cleans up the punctuation
// artifacts left behind. Intentionally conservative: skips ambiguous
// fillers ("like", "you know") that have legitimate non-filler uses,
// and only fires when the user explicitly enables it via Settings →
// Remove filler words. Applied *after* TranscriptCorrector so explicit
// user corrections always win over filler stripping.

enum FillerWordRemover {
    /// Non-word interjections only. "like" and "you know" are excluded
    /// because they have valid non-filler meanings ("I like cats", "you
    /// know who"). Each entry is a regex fragment that allows the
    /// trailing letter to repeat, since real-world fillers stretch out
    /// ("ummm", "uhhhh", "ahhh", "hmmm") and the word-boundary lookahead
    /// would otherwise reject them.
    private static let fillerPatterns = ["um+", "uh+", "ah+", "er", "erm", "hm+"]

    static func apply(to text: String) -> (text: String, removedCount: Int) {
        guard !text.isEmpty else { return (text, 0) }

        // Word-boundary lookarounds include `'` (so "it's" stays one
        // token) and `-` (so "uh-huh", "uh-oh" don't get split apart).
        let alternation = fillerPatterns.joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}'\-])("# + alternation + #")(?![\p{L}\p{N}'\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, 0)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        // Preserve the original first-character casing — if the input
        // began with a capital (typical sentence start) the result
        // should too, even if the original capital was on a removed
        // filler ("Um, hello." → "Hello.", not "hello.").
        let firstCharWasUpper = text.first?.isUppercase ?? false

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        var result = mutable as String

        // Clean up artifacts left behind by removal:
        //   1. Doubled / orphan commas: "x, , y" → "x, y"
        //   2. Whitespace before punctuation: "x ." → "x."
        //   3. Multiple consecutive spaces → single space
        //   4. Leading punctuation / whitespace (".", ",", ";", ":")
        //   5. Trailing whitespace
        result = result.replacingOccurrences(of: #"\s*,\s*,"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,.;:]+"#, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if firstCharWasUpper, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return (result, matches.count)
    }
}

