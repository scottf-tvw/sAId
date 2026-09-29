// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
import CoreGraphics

enum HotkeyAction: Sendable, Equatable { case pressed, released, cancel, none }
struct HotkeyEventSnapshot: Sendable {
    let typeRawValue: UInt32
    let keycode: UInt16
    let flagsRawValue: UInt64
    let isAutoRepeat: Bool
}
struct Hotkey: Sendable, Equatable {
    let keycode: UInt16
    let modifierFlagsRawValue: UInt64?
    init(keycode: UInt16, modifierFlag: CGEventFlags? = nil) {
        self.keycode = keycode
        modifierFlagsRawValue = modifierFlag?.rawValue
    }
    static let rightOption = Hotkey(keycode: 61, modifierFlag: .maskAlternate)
}
struct HotkeyDecision: Sendable, Equatable {
    let action: HotkeyAction
    let suppress: Bool
}
/// Tracks the configured physical key independently of the aggregate modifier mask.
/// Cancellation ends the action, but the physical key stays down until its release.
struct HotkeyDecider: Sendable {
    let hotkey: Hotkey
    private var physicalDown = false
    private(set) var active = false
    private var suppressEscapeKeyUp = false

    init(hotkey: Hotkey = .rightOption) { self.hotkey = hotkey }

    /// Seed from a resource-boundary snapshot whenever event history was lost.
    /// An already-held key is inactive until released and pressed again.
    mutating func reset(physicalKeyDown: Bool = false) {
        physicalDown = physicalKeyDown
        active = false
        suppressEscapeKeyUp = false
    }

    mutating func transition(_ event: HotkeyEventSnapshot) -> HotkeyDecision {
        if event.keycode == 53 {
            if event.typeRawValue == CGEventType.keyDown.rawValue {
                if suppressEscapeKeyUp { return HotkeyDecision(action: .none, suppress: true) }
                guard active else { return HotkeyDecision(action: .none, suppress: false) }
                suppressEscapeKeyUp = true
                guard !event.isAutoRepeat else { return HotkeyDecision(action: .none, suppress: true) }
                active = false
                return HotkeyDecision(action: .cancel, suppress: true)
            }
            if event.typeRawValue == CGEventType.keyUp.rawValue, suppressEscapeKeyUp {
                suppressEscapeKeyUp = false
                return HotkeyDecision(action: .none, suppress: true)
            }
            return HotkeyDecision(action: .none, suppress: false)
        }
        guard event.keycode == hotkey.keycode else {
            return HotkeyDecision(action: .none, suppress: false)
        }

        if let mask = hotkey.modifierFlagsRawValue {
            guard event.typeRawValue == CGEventType.flagsChanged.rawValue else {
                return HotkeyDecision(action: .none, suppress: true)
            }
            // A flagsChanged event names the physical side that changed. The shared
            // flag may still be set when this side is released while the other is held.
            if physicalDown { return release() }
            guard event.flagsRawValue & mask != 0 else {
                return HotkeyDecision(action: .none, suppress: true)
            }
            return press()
        }
        if event.typeRawValue == CGEventType.keyDown.rawValue, !event.isAutoRepeat {
            return physicalDown ? HotkeyDecision(action: .none, suppress: true) : press()
        }
        if event.typeRawValue == CGEventType.keyUp.rawValue { return release() }
        return HotkeyDecision(action: .none, suppress: true)
    }

    private mutating func press() -> HotkeyDecision {
        physicalDown = true
        active = true
        return HotkeyDecision(action: .pressed, suppress: true)
    }

    private mutating func release() -> HotkeyDecision {
        physicalDown = false
        let action: HotkeyAction = active ? .released : .none
        active = false
        return HotkeyDecision(action: action, suppress: true)
    }
}
