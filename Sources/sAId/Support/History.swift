import Combine
import Foundation

/// Shared by every window. A corrupt source is preserved until explicit Clear,
/// which first archives it; new entries remain available in memory meanwhile.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var errorMessage: String?
    private let fileURL: URL
    private var corrupt = false

    init(fileURL: URL = AppFiles.directory.appendingPathComponent("history.json")) {
        self.fileURL = fileURL
        do { entries = Array(try AppFiles.load([DictationHistoryEntry].self, from: fileURL, fallback: []).prefix(50)) }
        catch { corrupt = true; errorMessage = "History could not be read. The original file is preserved; new entries remain in memory." }
    }
    func record(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(50))
        guard !corrupt else { return }
        persist()
    }
    func clear() {
        do {
            if corrupt { try AppFiles.archiveDamaged(fileURL) }
            try AppFiles.save([DictationHistoryEntry](), to: fileURL)
            corrupt = false; entries = []; errorMessage = nil
        } catch { errorMessage = "Could not clear History. Check access to Application Support/sAId." }
    }
    private func persist() {
        do { try AppFiles.save(entries, to: fileURL); errorMessage = nil }
        catch { errorMessage = "History could not be saved. Entries remain in memory." }
    }
}

enum AppFiles {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/sAId", isDirectory: true)
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL, fallback: Value) throws -> Value {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return fallback }
    }
    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    static func archiveDamaged(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("damaged-\(UUID().uuidString)"))
    }
}
