import Foundation

struct DictationHistoryEntry: Sendable, Equatable, Codable, Identifiable {
    enum Source: String, Sendable, Equatable, Codable { case final, previewAfterFinalFailure }
    let id: UUID
    let text: String
    let timestamp: Date
    let targetAppID: String?
    let source: Source
    let failure: String?
    init(id: UUID = UUID(), text: String, timestamp: Date, targetAppID: String?, source: Source, failure: String?) {
        self.id = id; self.text = text; self.timestamp = timestamp
        self.targetAppID = targetAppID; self.source = source; self.failure = failure
    }
}
