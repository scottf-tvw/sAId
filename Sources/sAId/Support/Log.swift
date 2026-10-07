import os

enum Log: Sendable {
    static func controller(_ message: String) {
        if message.hasPrefix("capture ") { audio.error("\(message, privacy: .public)") }
        else if message.hasPrefix("insert: ") { insert.error("\(message, privacy: .public)") }
        else { app.info("\(message, privacy: .public)") }
    }
    static let app = Logger(subsystem: "org.tvw.said", category: "app")
    static let audio = Logger(subsystem: "org.tvw.said", category: "audio")
    static let engine = Logger(subsystem: "org.tvw.said", category: "engine")
    static let insert = Logger(subsystem: "org.tvw.said", category: "insert")
    static let hotkey = Logger(subsystem: "org.tvw.said", category: "hotkey")
}
