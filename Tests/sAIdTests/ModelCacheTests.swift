import Foundation
import Synchronization
import XCTest
@testable import sAId

private struct FixtureTransport: ModelTransport {
    let action: @Sendable (URL, URL, @Sendable (Int64) -> Void) async throws -> Void
    func download(_ source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await action(source, destination, progress)
    }
}

@MainActor
final class ModelCacheTests: XCTestCase {
    private let bytes = Data("123456789".utf8) // Standard CRC32C vector: e3069283.
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func manifest(name: String = "model.bin", checksum: String = "4waSgw==", type: String = "crc32c") throws -> ModelManifest {
        try ModelManifest(json: Data("""
        {"groups":[{"base_url":"https://download.moonshine.ai/model/example","files":[{"name":"\(name)","size":9,"checksum":"\(checksum)","checksum_type":"\(type)"}]}]}
        """.utf8))
    }
    func testCompleteCacheIsOfflineAndSameSizeCorruptionIsRejected() async throws {
        let root = try root(), manifest = try manifest()
        let cache = ModelCache(root: root, manifest: manifest, transport: FixtureTransport { _, _, _ in XCTFail("Network on complete cache") })
        XCTAssertFalse(try cache.isComplete())
        try bytes.write(to: root.appendingPathComponent("model.bin"))
        XCTAssertTrue(try cache.isComplete())
        try await cache.ensurePresent()
        try Data("987654321".utf8).write(to: root.appendingPathComponent("model.bin"))
        XCTAssertFalse(try cache.isComplete())
    }
    func testPrimaryFailureUsesMirrorAndCommitsOnlyVerifiedFile() async throws {
        let root = try root(), calls = Mutex<[URL]>([]), progress = Mutex<[Double]>([])
        let bytes = bytes
        let cache = ModelCache(root: root, manifest: try manifest(), transport: FixtureTransport { source, destination, update in
            calls.withLock { $0.append(source) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("model.bin").path))
            if source.host == "download.moonshine.ai" { throw URLError(.badServerResponse) }
            XCTAssertEqual(source.absoluteString, "https://huggingface.co/moonshine-ai/moonshine-voice-assets/resolve/main/model/example/model.bin")
            update(-10); update(900)
            try bytes.write(to: destination)
        })
        try await cache.ensurePresent { value, _ in progress.withLock { $0.append(value) } }
        XCTAssertEqual(calls.withLock { $0.count }, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("model.bin")), bytes)
        XCTAssertTrue(progress.withLock { $0.allSatisfy { (0...1).contains($0) } })
        XCTAssertEqual(progress.withLock { $0.last }, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["model.bin"])
    }
    func testChecksumFailureNeverPublishesAndPreservesOldFile() async throws {
        let root = try root(), final = root.appendingPathComponent("model.bin")
        try Data("old".utf8).write(to: final)
        let cache = ModelCache(root: root, manifest: try manifest(), transport: FixtureTransport { _, target, _ in
            try Data("wrongdata".utf8).write(to: target)
        })
        do { try await cache.ensurePresent(); XCTFail("Expected integrity error") } catch {}
        XCTAssertEqual(try Data(contentsOf: final), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["model.bin"])
    }
    func testCancellationRemovesPartialAndDoesNotFallback() async throws {
        let root = try root(), calls = Mutex(0)
        let cache = ModelCache(root: root, manifest: try manifest(), transport: FixtureTransport { _, target, _ in
            calls.withLock { $0 += 1 }
            try Data("part".utf8).write(to: target)
            throw CancellationError()
        })
        do { try await cache.ensurePresent(); XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testIncompleteMultiFileCacheDownloadsOnlyMissingAsset() async throws {
        let root = try root(), bytes = bytes, calls = Mutex<[String]>([])
        let manifest = try ModelManifest(json: Data("""
        {"groups":[{"base_url":"https://download.moonshine.ai/model/example","files":[
        {"name":"first.bin","size":9,"checksum":"4waSgw==","checksum_type":"crc32c"},
        {"name":"second.bin","size":9,"checksum":"4waSgw==","checksum_type":"crc32c"}]}]}
        """.utf8))
        try bytes.write(to: root.appendingPathComponent("first.bin"))
        let cache = ModelCache(root: root, manifest: manifest, transport: FixtureTransport { source, target, _ in
            calls.withLock { $0.append(source.lastPathComponent) }
            try bytes.write(to: target)
        })
        XCTAssertFalse(try cache.isComplete())
        try await cache.ensurePresent()
        XCTAssertTrue(try cache.isComplete())
        XCTAssertEqual(calls.withLock { $0 }, ["second.bin"])
    }

    func testCancellationAfterSuccessfulTransportDoesNotPublishFile() async throws {
        let root = try root(), bytes = bytes, gate = DownloadGate()
        let cache = ModelCache(root: root, manifest: try manifest(), transport: FixtureTransport { _, target, _ in
            try bytes.write(to: target)
            await gate.pause()
        })
        let download = Task { try await cache.ensurePresent() }
        for _ in 0..<10_000 { if await gate.isPaused { break }; await Task.yield() }
        guard await gate.isPaused else { XCTFail("Download missed gate"); download.cancel(); return }
        download.cancel()
        await gate.resume()
        do { try await download.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRejectsUnsafePathsAndUnknownChecksums() throws {
        for name in ["../escape", "/absolute", "nested/file", ".", "..", ""] {
            XCTAssertThrowsError(try manifest(name: name))
        }
        XCTAssertThrowsError(try manifest(type: "unknown"))
        XCTAssertThrowsError(try manifest(checksum: "invalid"))
    }
    func testSymlinkDestinationCannotEscapeCache() async throws {
        let root = try root(), outside = try self.root().appendingPathComponent("outside")
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("model.bin"), withDestinationURL: outside)
        let cache = ModelCache(root: root, manifest: try manifest(), transport: FixtureTransport { _, _, _ in XCTFail("Unsafe destination") })
        XCTAssertThrowsError(try cache.isComplete())
        do { try await cache.ensurePresent(); XCTFail("Expected unsafe destination") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isPaused: Bool { continuation != nil }
    func pause() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
