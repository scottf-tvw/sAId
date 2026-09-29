// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
import CoreGraphics

@MainActor
struct SystemInsertionEvents: InsertionEvents {
    private func source() throws -> CGEventSource {
        // Preflight only: the permissions UI owns requests. Unit tests inject the whole event boundary.
        guard CGPreflightPostEventAccess() else { throw TextInsertionError.permissionUnavailable }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextInsertionError.eventCreationFailed
        }
        return source
    }

    func preparePaste() throws -> [any PreparedInsertionEvent] {
        try prepare(InsertionEventPlan.paste)
    }

    func prepareUnicode(_ chunks: [[UInt16]]) throws -> [any PreparedInsertionEvent] {
        try prepare(InsertionEventPlan.unicode(chunks))
    }

    private func prepare(_ plans: [InsertionEventPlan]) throws -> [any PreparedInsertionEvent] {
        let source = try source()
        return try plans.map { plan in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: plan.keycode, keyDown: plan.keyDown) else {
                throw TextInsertionError.eventCreationFailed
            }
            event.flags = CGEventFlags(rawValue: plan.flagsRawValue)
            event.setIntegerValueField(.eventSourceUserData, value: plan.sourceUserData)
            plan.unicode.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress, !buffer.isEmpty {
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                }
            }
            return SystemPreparedInsertionEvent(event: event)
        }
    }
}

@MainActor
private struct SystemPreparedInsertionEvent: PreparedInsertionEvent {
    let event: CGEvent
    func post() { event.post(tap: .cghidEventTap) }
}

/// Pure event descriptions let insertion/hotkey interoperability be checked without native input APIs.
struct InsertionEventPlan: Sendable {
    let keycode: UInt16
    let keyDown: Bool
    let flagsRawValue: UInt64
    let unicode: [UInt16]
    var sourceUserData: Int64 { EventOrigin.insertion }

    static let paste = [
        InsertionEventPlan(keycode: 0x09, keyDown: true, flagsRawValue: CGEventFlags.maskCommand.rawValue, unicode: []),
        InsertionEventPlan(keycode: 0x09, keyDown: false, flagsRawValue: CGEventFlags.maskCommand.rawValue, unicode: [])
    ]

    static func unicode(_ chunks: [[UInt16]]) -> [InsertionEventPlan] {
        chunks.map { InsertionEventPlan(keycode: 0, keyDown: true, flagsRawValue: 0, unicode: $0) }
    }
}
