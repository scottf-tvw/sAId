import os

enum Log: Sendable {
    static let app = Logger(subsystem: "org.tvw.said", category: "app")
    static let audio = Logger(subsystem: "org.tvw.said", category: "audio")
    static let engine = Logger(subsystem: "org.tvw.said", category: "engine")
    static let insert = Logger(subsystem: "org.tvw.said", category: "insert")
    static let hotkey = Logger(subsystem: "org.tvw.said", category: "hotkey")
}
