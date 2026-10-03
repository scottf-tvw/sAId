// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
import Carbon
import Foundation

protocol TextSink: Sendable {
    /// Returns after delivery was attempted and clipboard cleanup completed.
    /// Target applications provide no universal acknowledgment of acceptance.
    func insert(_ text: String) async throws
}

enum TextInsertionStrategy: String, Sendable, CaseIterable, Codable {
    case clipboardPaste, directUnicode
}

enum TextInsertionError: Error, Equatable {
    case secureInput, secureInputUnverified, focusChanged, permissionUnavailable, eventCreationFailed
    case snapshotFailed, clipboardWriteFailed, clipboardChanged, clipboardRestoreFailed
    case insertionInProgress

    /// Explicit allowlist: never serialize arbitrary Error descriptions or clipboard content.
    var diagnosticCategory: String {
        switch self {
        case .secureInput: "secureInput"
        case .secureInputUnverified: "secureInputUnverified"
        case .focusChanged: "focusChanged"
        case .permissionUnavailable: "permissionUnavailable"
        case .eventCreationFailed: "eventCreationFailed"
        case .snapshotFailed: "snapshotFailed"
        case .clipboardWriteFailed: "clipboardWriteFailed"
        case .clipboardChanged: "clipboardChanged"
        case .clipboardRestoreFailed: "clipboardRestoreFailed"
        case .insertionInProgress: "insertionInProgress"
        }
    }
    var userMessage: String {
        switch self {
        case .secureInput: "Secure input field"
        case .secureInputUnverified: "Secure Input active — refocus or close password dialogs"
        case .focusChanged: "Focus changed — try again or copy from History"
        default: "Paste failed — copy from History"
        }
    }
}

@MainActor
protocol PreparedInsertionEvent {
    /// Posting has no return receipt; it must never be treated as proof of target acceptance.
    func post()
}

@MainActor
protocol InsertionEvents {
    /// Prepare the entire sequence before any event is posted, so creation failure is pre-delivery.
    func preparePaste() throws -> [any PreparedInsertionEvent]
    func prepareUnicode(_ chunks: [[UInt16]]) throws -> [any PreparedInsertionEvent]
}

/// Ownership spans the restore delay, including cancellation, across all inserter instances.
@MainActor
final class TextInserter: TextSink {
    var strategy: TextInsertionStrategy
    var allowsUnicodeFallback: Bool
    private static var inserting = false
    private(set) static var latestSecurityCheck: InsertionSecurityCheck?
    private let pasteboard: any InsertionPasteboard
    private let events: any InsertionEvents
    private let secureInput: @MainActor () -> Bool
    private let focusedInput: @MainActor () -> FocusedInputSecurity
    private let delay: @MainActor (Duration) async throws -> Void

    init(pasteboard: any InsertionPasteboard = SystemInsertionPasteboard(),
         events: any InsertionEvents = SystemInsertionEvents(),
         strategy: TextInsertionStrategy = .clipboardPaste,
         allowsUnicodeFallback: Bool = true,
         secureInput: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
         focusedInput: @escaping @MainActor () -> FocusedInputSecurity = { FocusedInputSecurity.current() },
         delay: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.pasteboard = pasteboard
        self.events = events
        self.strategy = strategy
        self.allowsUnicodeFallback = allowsUnicodeFallback
        self.secureInput = secureInput
        self.focusedInput = focusedInput
        self.delay = delay
    }

    func insert(_ text: String) async throws {
        guard !Self.inserting else { throw TextInsertionError.insertionInProgress }
        Self.inserting = true
        defer { Self.inserting = false }
        try checkDeliveryAllowed()
        guard !text.isEmpty else { return }
        switch strategy {
        case .clipboardPaste: try await paste(text)
        case .directUnicode: try unicode(text)
        }
    }

    private func paste(_ text: String) async throws {
        var snapshot: PasteboardSnapshot?
        var ownedGeneration: Int?
        var posted = false
        do {
            let prepared = try events.preparePaste()
            guard !prepared.isEmpty else { throw TextInsertionError.eventCreationFailed }
            let saved = try PasteboardSnapshot(pasteboard: pasteboard)
            snapshot = saved
            guard pasteboard.changeCount == saved.changeCount else { throw TextInsertionError.clipboardChanged }
            let generation = pasteboard.clearContents()
            ownedGeneration = generation
            guard pasteboard.changeCount == generation else { throw TextInsertionError.clipboardChanged }
            guard pasteboard.writeItems([["public.utf8-plain-text": Data(text.utf8)]]) else {
                throw TextInsertionError.clipboardWriteFailed
            }
            guard pasteboard.changeCount == generation else { throw TextInsertionError.clipboardChanged }
            for event in prepared {
                try checkDeliveryAllowed()
                posted = true
                event.post()
            }
            try await delay(.milliseconds(150))
            try Task.checkCancellation()
        } catch {
            if let snapshot, let ownedGeneration {
                try snapshot.restore(to: pasteboard, ifOwnedBy: ownedGeneration)
            }
            // Never retry delivery after even one event was posted, nor after security/ownership changes.
            if !posted, allowsUnicodeFallback,
               let failure = error as? TextInsertionError,
               [.eventCreationFailed, .snapshotFailed, .clipboardWriteFailed].contains(failure) {
                try unicode(text)
                return
            }
            throw error
        }
        if let snapshot, let ownedGeneration {
            try snapshot.restore(to: pasteboard, ifOwnedBy: ownedGeneration)
        }
    }

    private func unicode(_ text: String) throws {
        try checkDeliveryAllowed()
        let prepared = try events.prepareUnicode(unicodeInsertionChunks(for: text))
        guard !prepared.isEmpty else { throw TextInsertionError.eventCreationFailed }
        for event in prepared {
            try checkDeliveryAllowed()
            event.post()
        }
    }

    private func checkDeliveryAllowed() throws {
        try Task.checkCancellation()
        let field = focusedInput()
        let check = InsertionSecurityCheck(globalSecureInput: secureInput(), focusedInput: field)
        Self.latestSecurityCheck = check
        if let refusal = check.refusal { throw refusal }
    }
}

/// Graphemes stay intact even when one is longer than the preferred chunk size.
func unicodeInsertionChunks(for text: String, maxUTF16UnitsPerEvent maxUnits: Int = 20) -> [[UInt16]] {
    guard maxUnits > 0 else { return [] }
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []
    for character in text {
        let units = Array(String(character).utf16)
        if !current.isEmpty, current.count + units.count > maxUnits {
            chunks.append(current)
            current = []
        }
        current.append(contentsOf: units)
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}
