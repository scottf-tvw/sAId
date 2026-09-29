import CryptoKit
import Darwin
import Foundation
import Moonshine
import MoonshineVoice

public let defaultModelRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/sAId/models/moonshine", isDirectory: true)

public typealias ModelProgress = @Sendable (Double, String) -> Void

public enum ModelCacheError: Error, Equatable {
    case incomplete, invalidManifest, unsafePath(String), integrity(String), http(Int), catalog(Int32)
}

struct ModelManifest: Sendable {
    struct File: Sendable, Decodable {
        let name: String
        let url: URL
        let size: Int64?
        let checksum: String?
        let checksumType: String?
        var mirror: URL {
            URL(string: "https://huggingface.co/moonshine-ai/moonshine-voice-assets/resolve/main" + url.path)!
        }
    }
    let files: [File]

    init(json: Data) throws {
        struct Catalog: Decodable { let groups: [Group] }
        struct Group: Decodable { let base_url: String; let files: [Entry] }
        struct Entry: Decodable {
            let name: String; let url: String?; let size: Int64?; let checksum: String?; let checksum_type: String?
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: json)
        var files: [File] = [], names = Set<String>()
        for group in catalog.groups {
            for entry in group.files {
                guard !entry.name.isEmpty, entry.name != ".", entry.name != "..",
                      !entry.name.contains("/"), !entry.name.contains("\\"), !entry.name.contains("\0"),
                      names.insert(entry.name).inserted else { throw ModelCacheError.unsafePath(entry.name) }
                guard let url = URL(string: entry.url ?? (group.base_url + "/" + entry.name)),
                      url.scheme == "https", url.host == "download.moonshine.ai",
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      url.path.hasPrefix("/model/"), !url.pathComponents.contains(".."),
                      url.lastPathComponent == entry.name,
                      entry.size.map({ $0 > 0 }) ?? true else { throw ModelCacheError.invalidManifest }
                if let checksum = entry.checksum, !checksum.isEmpty {
                    let count: Int
                    switch entry.checksum_type { case "crc32c": count = 4; case "sha256": count = 32
                    default: throw ModelCacheError.invalidManifest }
                    guard Data(base64Encoded: checksum)?.count == count else { throw ModelCacheError.invalidManifest }
                }
                files.append(File(name: entry.name, url: url, size: entry.size, checksum: entry.checksum, checksumType: entry.checksum_type))
            }
        }
        guard !files.isEmpty else { throw ModelCacheError.invalidManifest }
        self.files = files
    }

    /// The native catalog is bundled with the pinned framework; resolving it needs no network.
    static func englishMedium() throws -> Self {
        var json: UnsafeMutablePointer<CChar>?
        let status = "model_arch".withCString { name in
            String(ModelArch.mediumStreaming.rawValue).withCString { value in
                var option = moonshine_option_t(name: name, value: value)
                return moonshine_get_stt_dependencies("en", &option, 1, &json)
            }
        }
        defer { free(json) }
        guard status == 0, let json else { throw ModelCacheError.catalog(status) }
        return try Self(json: Data(String(cString: json).utf8))
    }
}

protocol ModelTransport: Sendable {
    /// Writes only to the provided staging path; returns after the file is closed.
    func download(_ source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

struct HTTPModelTransport: ModelTransport {
    func download(_ source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw ModelCacheError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        progress(Int64(size))
    }
}

/// Checked Sendable value: immutable configuration; each attempt owns a unique staging file.
struct ModelCache: Sendable {
    let root: URL
    let manifest: ModelManifest
    let transport: any ModelTransport

    init(root: URL, manifest: ModelManifest, transport: any ModelTransport = HTTPModelTransport()) {
        self.root = root; self.manifest = manifest; self.transport = transport
    }

    func isComplete() throws -> Bool {
        for file in manifest.files {
            try Task.checkCancellation()
            if try !valid(root.appendingPathComponent(file.name), file: file) { return false }
        }
        return true
    }

    func ensurePresent(progress: ModelProgress? = nil) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let count = Double(manifest.files.count)
        for (index, file) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let target = root.appendingPathComponent(file.name)
            progress?(Double(index) / count, "Checking \(file.name)")
            if try valid(target, file: file) { continue }
            for (attempt, source) in [file.url, file.mirror].enumerated() {
                let staged = root.appendingPathComponent(".\(UUID().uuidString).part")
                defer { try? FileManager.default.removeItem(at: staged) }
                do {
                    try await transport.download(source, to: staged) { bytes in
                        let fraction = file.size.map { min(1, max(0, Double(bytes) / Double($0))) } ?? 0
                        progress?((Double(index) + fraction) / count, "Downloading \(file.name)")
                    }
                    try Task.checkCancellation()
                    guard try valid(staged, file: file) else { throw ModelCacheError.integrity(file.name) }
                    try Task.checkCancellation()
                    // Reject links again after suspension. POSIX rename atomically replaces only this entry.
                    try rejectSymlink(target)
                    guard rename(staged.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    break
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if attempt == 1 { throw error }
                    progress?(Double(index) / count, "Retrying \(file.name) from official mirror")
                }
            }
        }
        progress?(1, "Model ready")
    }

    private func rejectSymlink(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw ModelCacheError.unsafePath(url.lastPathComponent) }
    }
    private func valid(_ url: URL, file: ModelManifest.File) throws -> Bool {
        try rejectSymlink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ModelCacheError.unsafePath(file.name) }
        if let size = file.size, Int64(values.fileSize ?? -1) != size { return false }
        guard let checksum = file.checksum, !checksum.isEmpty else { return true }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc: UInt32 = .max, sha = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            if file.checksumType == "crc32c" { crc = CRC32C.update(crc, data: chunk) }
            else { sha.update(data: chunk) }
        }
        let digest: Data
        if file.checksumType == "crc32c" {
            var value = (crc ^ .max).bigEndian
            digest = withUnsafeBytes(of: &value) { Data($0) }
        } else { digest = Data(sha.finalize()) }
        return digest.base64EncodedString() == checksum
    }
}

private enum CRC32C {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0x82F63B78 : crc >> 1 }
        return crc
    }
    static func update(_ initial: UInt32, data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            table.withUnsafeBufferPointer { table in
                var crc = initial
                for byte in bytes.bindMemory(to: UInt8.self) { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
                return crc
            }
        }
    }
}
