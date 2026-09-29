import Foundation

struct DictationHistoryEntry: Sendable, Equatable {
    enum Source: Sendable, Equatable { case final, previewAfterFinalFailure }
    let text: String
    let timestamp: Date
    let targetAppID: String?
    let source: Source
    let failure: String?
}
