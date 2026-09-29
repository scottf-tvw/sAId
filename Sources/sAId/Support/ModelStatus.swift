import Foundation

struct ModelStatus: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var readiness: ModelReadiness = .loading
    private(set) var progress = 0.0
    private(set) var detail = "Loading Moonshine…"
    mutating func begin() -> UInt64 {
        generation += 1; readiness = .loading; progress = 0; detail = "Loading Moonshine…"
        return generation
    }
    mutating func update(progress: Double, detail: String, generation: UInt64) {
        guard generation == self.generation, readiness == .loading else { return }
        self.progress = min(1, max(0, progress)); self.detail = detail
    }
    mutating func finish(_ readiness: ModelReadiness, generation: UInt64) {
        guard generation == self.generation else { return }
        self.readiness = readiness
        switch readiness {
        case .ready: progress = 1; detail = "Ready · English Medium Streaming"
        case .loading: detail = "Loading Moonshine…"
        case .failed(let reason): detail = reason
        }
    }
}

enum AppModelCache {
    /// No caller-supplied deletion path: only the fixed model child of app support.
    /// Reject a redirected app directory or model directory before deletion.
    static func removeOwnedCache(root: URL = AppFiles.directory) throws {
        let models = root.appendingPathComponent("models", isDirectory: true)
        let cache = models.appendingPathComponent("moonshine", isDirectory: true)
        for url in [root, models, cache] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ModelCacheError.unsafePath(url.lastPathComponent)
            }
        }
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
    }
}
