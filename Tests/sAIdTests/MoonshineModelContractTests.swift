@testable import SaidEngine
import Foundation
import MoonshineVoice
import XCTest
@testable import sAId

/// Offline pipeline contracts, explicitly enabled. These corpus clips do not measure Scott's accuracy.
@MainActor
final class MoonshineModelContractTests: XCTestCase {
    func testAllFixturesAndRepeatSessionsOnOneResidentModel() async throws {
        guard ProcessInfo.processInfo.environment["SAID_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set SAID_MODEL_TESTS=1 to run offline cached-model contracts")
        }
        let cache = SaidEngine.ModelCache(root: defaultModelRoot, manifest: try .englishMedium())
        guard try cache.isComplete() else { throw XCTSkip("Complete verified cached model unavailable; never download in contracts") }
        let engine = MoonshineEngine()
        let loadStart = Date()
        try await engine.load(progress: nil, downloadIfMissing: false)
        print("MODEL load including verification: \(Date().timeIntervalSince(loadStart)) s")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let references = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtures.appendingPathComponent("transcripts.json")))
        for repetition in 1...2 {
            for name in references.keys.sorted() {
                let wav = try loadWAVFile(fixtures.appendingPathComponent(name).path)
                XCTAssertEqual(wav.sampleRate, 16_000)
                let begin = Date()
                let stream = try await engine.start()
                for offset in stride(from: 0, to: wav.audioData.count, by: 4800) {
                    try await engine.feed(Array(wav.audioData[offset..<min(offset + 4800, wav.audioData.count)]))
                }
                await engine.stop()
                var lines: [PreviewLine] = []
                for try await line in stream { lines.append(line) }
                let text = try XCTUnwrap(lines.last?.text)
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertTrue(lines.contains { !$0.isFinal && !$0.text.isEmpty }, "Expected live partial for \(name)")
                XCTAssertEqual(lines.last?.isFinal, true)
                let wer = contractWER(reference: try XCTUnwrap(references[name]), hypothesis: text)
                XCTAssertLessThanOrEqual(wer, 0.5, "Pipeline regression for \(name): \(text)")
                print("MODEL repetition \(repetition) \(name): \(text) | WER \(wer) | snapshots \(lines.count) | wall \(Date().timeIntervalSince(begin)) s")
            }
        }
    }
}

/// Literal lowercase alphanumeric tokens; punctuation separates words. No number expansion or reference rewriting.
func contractWER(reference: String, hypothesis: String) -> Double {
    let expected = reference.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let actual = hypothesis.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    var previous = Array(0...actual.count)
    for (i, word) in expected.enumerated() {
        var current = [i + 1]
        for (j, candidate) in actual.enumerated() {
            current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (word == candidate ? 0 : 1)))
        }
        previous = current
    }
    return Double(previous.last ?? 0) / Double(max(expected.count, 1))
}
