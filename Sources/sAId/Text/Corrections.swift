// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
import Foundation

struct Correction: Codable, Equatable, Sendable {
    var from: String
    var to: String

    static let defaults = [
        Correction(from: "invintus", to: "Invintus"),
        Correction(from: "tvw", to: "TVW"),
        Correction(from: "mimo live", to: "mimoLive"),
        Correction(from: "live bus", to: "LAIveBus"),
        Correction(from: "ndi", to: "NDI"),
    ]
}

/// Missing files return defaults without creating a file. Malformed or unreadable files throw.
struct CorrectionsStore: Sendable {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/sAId/corrections.json")
    }
    let fileURL: URL

    init(fileURL: URL = Self.defaultURL) { self.fileURL = fileURL }

    func load() throws -> [Correction] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Correction.defaults
        }
        return try JSONDecoder().decode([Correction].self, from: data)
    }

    /// An explicit save atomically replaces the file; load never repairs or overwrites it.
    func save(_ corrections: [Correction]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(corrections)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// UTF-16 offsets match Foundation regex ranges. Protection travels with each code unit,
/// including literal correction replacements; there are no placeholder/sentinel strings.
struct ProtectedText {
    private var units: [UInt16]
    private var protected: [Bool]
    var string: String { String(decoding: units, as: UTF16.self) }

    init(_ text: String) {
        units = Array(text.utf16)
        protected = Array(repeating: false, count: units.count)
        for match in Self.matches(#"\S+"#, in: text) {
            let token = (text as NSString).substring(with: match.range)
            let code = #"[\p{L}\p{M}][/_\.][\p{L}\p{M}]|_"#
            if !Self.matches(#"\p{N}"#, in: token).isEmpty ||
                !Self.matches(code, in: token).isEmpty ||
                !Self.matches(#"(?i)(?<![\p{L}\p{M}\p{N}])(?:[a-z][a-z0-9+.-]*://|www\.)"#, in: token).isEmpty {
                protected.replaceSubrange(match.range.location..<NSMaxRange(match.range), with: repeatElement(true, count: match.range.length))
            }
        }
    }

    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }

    static func normalizedSource(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func wordPattern(_ source: String, filler: Bool = false) -> String? {
        let words = source.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let boundary = filler ? #"\p{L}\p{M}\p{N}_'’\-"# : #"\p{L}\p{M}\p{N}_"#
        return "(?i)(?<![" + boundary + "])" + words.joined(separator: #"\s+"#) + "(?![" + boundary + "])"
    }

    func isProtected(_ range: NSRange) -> Bool {
        protected[range.location..<NSMaxRange(range)].contains(true)
    }

    mutating func replace(_ range: NSRange, with replacement: String, protect: Bool = false) {
        let span = range.location..<NSMaxRange(range)
        let newUnits = Array(replacement.utf16)
        units.replaceSubrange(span, with: newUnits)
        protected.replaceSubrange(span, with: repeatElement(protect, count: newUnits.count))
    }

    mutating func rewrite(_ pattern: String, replacement: (String) -> String) {
        let snapshot = string
        for match in Self.matches(pattern, in: snapshot).reversed() where !isProtected(match.range) {
            replace(match.range, with: replacement((snapshot as NSString).substring(with: match.range)))
        }
    }

    mutating func correct(_ corrections: [Correction]) {
        let snapshot = string
        var chosen: [(NSRange, String)] = []
        // Select all matches against the original input: replacements never cascade.
        let ranked = corrections.enumerated().map {
            (order: $0.offset, rule: $0.element, length: Self.normalizedSource($0.element.from).count)
        }
        for rule in ranked.sorted(by: {
            $0.length == $1.length ? $0.order < $1.order : $0.length > $1.length
        }).map(\.rule) {
            guard let pattern = Self.wordPattern(rule.from) else { continue }
            for match in Self.matches(pattern, in: snapshot) where !isProtected(match.range) {
                guard !chosen.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
                chosen.append((match.range, rule.to))
            }
        }
        for (range, replacement) in chosen.sorted(by: { $0.0.location > $1.0.location }) {
            replace(range, with: replacement, protect: true)
        }
    }

    mutating func capitalizeFirstWord() {
        let snapshot = string
        guard let word = Self.matches(#"[\p{L}\p{M}]+"#, in: snapshot).first,
              !isProtected(word.range) else { return }
        let token = (snapshot as NSString).substring(with: word.range)
        // Preserve established internal brand casing, e.g. iPhone and macOS.
        guard !token.dropFirst().contains(where: \.isUppercase), let first = token.first else { return }
        replace(NSRange(location: word.range.location, length: String(first).utf16.count), with: first.uppercased())
    }
}
