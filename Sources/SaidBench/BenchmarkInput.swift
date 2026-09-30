import Foundation

struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Literal lowercase alphanumeric tokens. Punctuation separates words; numbers are not expanded.
struct WordError: Equatable {
    let edits: Int
    let references: Int
    var rate: Double? { references == 0 ? (edits == 0 ? 0 : nil) : Double(edits) / Double(references) }
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(edits: lhs.edits + rhs.edits, references: lhs.references + rhs.references)
    }
    static func measure(reference: String, hypothesis: String) -> Self {
        let expected = reference.lowercased().split { !$0.isLetter && !$0.isNumber }
        let actual = hypothesis.lowercased().split { !$0.isLetter && !$0.isNumber }
        var previous = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var current = [i + 1]
            for (j, candidate) in actual.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (word == candidate ? 0 : 1)))
            }
            previous = current
        }
        return Self(edits: previous.last ?? 0, references: expected.count)
    }
}

struct PCM16WAV {
    let samples: [Float]
    var duration: Double { Double(samples.count) / 16_000 }
    init(data: Data) throws {
        let bytes = [UInt8](data)
        func tag(_ offset: Int) -> String { String(decoding: bytes[offset..<offset + 4], as: UTF8.self) }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE", u32(4) == bytes.count - 8 else {
            throw BenchmarkError("Invalid or truncated RIFF/WAVE container")
        }
        var offset = 12, formatSeen = false, audio: Range<Int>?
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw BenchmarkError("Truncated WAV chunk header") }
            let name = tag(offset), count = u32(offset + 4), start = offset + 8
            guard count <= bytes.count - start, count + (count % 2) <= bytes.count - start else {
                throw BenchmarkError("Truncated WAV chunk: \(name)")
            }
            if name == "fmt " {
                guard !formatSeen, count >= 16, u16(start) == 1, u16(start + 2) == 1,
                      u32(start + 4) == 16_000, u32(start + 8) == 32_000,
                      u16(start + 12) == 2, u16(start + 14) == 16 else {
                    throw BenchmarkError("WAV must be 16000 Hz mono PCM16 with valid alignment/rate")
                }
                formatSeen = true
            } else if name == "data" {
                guard audio == nil, count > 0, count % 2 == 0 else { throw BenchmarkError("Invalid or duplicate WAV audio chunk") }
                audio = start..<start + count
            }
            offset = start + count + count % 2
        }
        guard formatSeen, let audio else { throw BenchmarkError("Missing WAV format or audio chunk") }
        samples = stride(from: audio.lowerBound, to: audio.upperBound, by: 2).map {
            Float(Int16(bitPattern: UInt16(u16($0)))) / 32768
        }
        // PCM16 decoding guarantees finite normalized samples.
    }
}

struct BenchmarkCorpus {
    struct Entry { let filename: String; let reference: String; let audio: PCM16WAV }
    let entries: [Entry]
    init(directory: URL, references: URL) throws {
        let texts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: references))
        guard !texts.isEmpty else { throw BenchmarkError("Reference JSON must contain at least one WAV/text pair") }
        entries = try texts.keys.sorted().map { name in
            guard name.hasSuffix(".wav"), !name.contains("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw BenchmarkError("Reference keys must be plain .wav filenames: \(name)")
            }
            do {
                return Entry(filename: name, reference: texts[name]!,
                             audio: try PCM16WAV(data: Data(contentsOf: directory.appendingPathComponent(name))))
            } catch { throw BenchmarkError("\(name): \(error)") }
        }
    }
}
