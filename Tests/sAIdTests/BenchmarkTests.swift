import Foundation
import XCTest
@testable import SaidBench
import SaidEngine

final class BenchmarkTests: XCTestCase {
    func testLiteralTokensAndEditCounts() {
        XCTAssertEqual(WordError.measure(reference: "Hello, WORLD! 21", hypothesis: "hello world twenty one"), WordError(edits: 2, references: 3))
        XCTAssertEqual(WordError.measure(reference: "a b c", hypothesis: "a c"), WordError(edits: 1, references: 3))
        XCTAssertEqual(WordError.measure(reference: "a b", hypothesis: "a x b"), WordError(edits: 1, references: 2))
        XCTAssertEqual(WordError.measure(reference: "", hypothesis: "extra words"), WordError(edits: 2, references: 0))
        XCTAssertNil(WordError(edits: 2, references: 0).rate)
        XCTAssertEqual(WordError(edits: 0, references: 0).rate, 0)
        let corpus = WordError.measure(reference: "a", hypothesis: "x") + WordError.measure(reference: "a b c", hypothesis: "a b c")
        XCTAssertEqual(corpus.rate, 0.25)
    }
    func testWAVSignedSamplesAndUnknownPaddedChunk() throws {
        let wav = try PCM16WAV(data: fixture(extra: true))
        XCTAssertEqual(wav.samples, [-1, 0, Float(32767) / 32768])
        XCTAssertEqual(wav.duration, 3.0 / 16000)
    }
    func testRejectsMalformedWAVs() {
        let good = fixture()
        for length in 0..<good.count { XCTAssertThrowsError(try PCM16WAV(data: good.prefix(length))) }
        for (offset, value) in [(0, 0), (8, 0), (20, 3), (22, 2), (24, 0), (28, 1), (32, 4), (34, 8), (40, 5)] {
            var bytes = good; bytes[offset] = UInt8(value)
            XCTAssertThrowsError(try PCM16WAV(data: bytes), "Accepted invalid header at \(offset)")
        }
        var trailing = good; trailing.append(0)
        XCTAssertThrowsError(try PCM16WAV(data: trailing))
    }
    func testCorpusRejectsUnsafeNamesAndInvalidAudioBeforeModelLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = root.appendingPathComponent("transcripts.json")
        for dict in [[String: String](), ["../escape.wav": "text"], ["bad.txt": "text"], ["bad.wav": "text"]] {
            try JSONEncoder().encode(dict).write(to: refs)
            XCTAssertThrowsError(try BenchmarkCorpus(directory: root, references: refs))
        }
        try fixture().write(to: root.appendingPathComponent("ok.wav"))
        try JSONEncoder().encode(["ok.wav": "Unchanged TEXT 21"]).write(to: refs)
        let corpus = try BenchmarkCorpus(directory: root, references: refs)
        XCTAssertEqual(corpus.entries.first?.reference, "Unchanged TEXT 21")
    }
    @MainActor
    func testCLIRejectsBadOptionsAndFailsOfflineForMissingModel() async throws {
        for arguments in [[], ["--unknown"], ["--model-root"]] {
            do { try await BenchmarkMain.run(arguments); XCTFail("Accepted invalid options") }
            catch { XCTAssertTrue(error is BenchmarkError) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = root.appendingPathComponent("transcripts.json")
        try JSONEncoder().encode(["ok.wav": "text"]).write(to: refs)
        let arguments = ["--model-root", root.appendingPathComponent("missing-model").path, root.path, refs.path]
        do { try await BenchmarkMain.run(arguments); XCTFail("Accepted missing WAV") }
        catch { XCTAssertTrue(error is BenchmarkError, "Audio must fail before model load") }
        try fixture().write(to: root.appendingPathComponent("ok.wav"))
        do { try await BenchmarkMain.run(arguments); XCTFail("Accepted missing model") }
        catch { XCTAssertEqual(error as? ModelCacheError, .incomplete) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing-model").path))
    }
    private func fixture(extra: Bool = false) -> Data {
        var payload = Data("WAVE".utf8)
        func u16(_ n: UInt16) -> Data { Data([UInt8(n & 255), UInt8(n >> 8)]) }
        func u32(_ n: UInt32) -> Data { Data((0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        if extra { payload.append(Data("JUNK".utf8)); payload.append(u32(1)); payload.append(contentsOf: [42, 0]) }
        payload.append(Data("fmt ".utf8)); payload.append(u32(16))
        for n: UInt16 in [1, 1] { payload.append(u16(n)) }
        payload.append(u32(16000)); payload.append(u32(32000)); payload.append(u16(2)); payload.append(u16(16))
        payload.append(Data("data".utf8)); payload.append(u32(6))
        for n: UInt16 in [32768, 0, 32767] { payload.append(u16(n)) }
        return Data("RIFF".utf8) + u32(UInt32(payload.count)) + payload
    }
}
