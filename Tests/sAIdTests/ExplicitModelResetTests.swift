import Foundation
import Synchronization
import Testing
@testable import sAId

private final class ModelOwnershipProbe: Sendable {
    let count = Mutex(0)
}
private final class OwnedRuntime: MoonshineRuntime {
    let probe: ModelOwnershipProbe
    init(_ probe: ModelOwnershipProbe) { self.probe = probe; probe.count.withLock { $0 += 1 } }
    deinit { probe.count.withLock { $0 -= 1 } }
    func makeStream() throws -> any PreviewRuntimeStream { throw MoonshineEngineError.notStreaming }
    func setKeyterms(_ terms: [String]) throws {}
    func transcribeWithoutStreaming(audioData: [Float], sampleRate: Int32, flags: UInt32) throws -> [String] { ["test"] }
}
struct ExplicitModelResetTests {
    @Test func explicitResetReleasesNativeEvenWhenEngineIsRetained() async throws {
        let probe = ModelOwnershipProbe()
        let engine = MoonshineEngine(runtimeFactory: { _ in OwnedRuntime(probe) })
        try await engine.load()
        #expect(probe.count.withLock { $0 } == 1)
        try await engine.releaseForExplicitReset()
        #expect(probe.count.withLock { $0 } == 0)
        do { _ = try await engine.transcribe([0.1]); Issue.record("Expected unloaded engine") }
        catch { #expect(error is MoonshineEngineError) }
        try await engine.load()
        #expect(probe.count.withLock { $0 } == 1)
    }
    @Test func resetOnlyTouchesOwnedCacheAndRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("models/moonshine")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history.json")
        try Data("history".utf8).write(to: history)
        try Data("model".utf8).write(to: cache.appendingPathComponent("weights"))
        try AppModelCache.removeOwnedCache(root: root)
        #expect(FileManager.default.fileExists(atPath: history.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: root)
        #expect(throws: (any Error).self) { try AppModelCache.removeOwnedCache(root: root) }
        #expect(FileManager.default.fileExists(atPath: history.path))
    }
}
