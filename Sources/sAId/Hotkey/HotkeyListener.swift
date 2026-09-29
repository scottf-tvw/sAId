// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
import CoreGraphics

/// Resource boundary: tests replace only the system tap, never synthesize input.
@MainActor
protocol HotkeyTap: AnyObject {
    func start(handler: @escaping @MainActor (HotkeyEventSnapshot) -> Bool) -> Bool
    func stop()
    func enable()
    func isKeyDown(_ keycode: UInt16) -> Bool
}

@MainActor
final class HotkeyListener {
    /// Called synchronously in tap order. Keep work here brief to avoid tap timeouts.
    var onAction: (@MainActor (HotkeyAction) -> Void)?
    /// Controller-owned eligibility includes pending physical actions, not delayed HUD state.
    var canCancel: (@MainActor () -> Bool)?
    private let tap: any HotkeyTap
    private var decider: HotkeyDecider
    private var running = false

    init(hotkey: Hotkey = .rightOption, tap: any HotkeyTap = SystemHotkeyTap()) {
        self.tap = tap
        decider = HotkeyDecider(hotkey: hotkey)
    }

    isolated deinit { if running { tap.stop() } }

    @discardableResult
    func start() -> Bool {
        if running { tap.enable(); return true }
        running = tap.start { [weak self] snapshot in
            guard let self, self.running else { return false }
            return self.handle(snapshot)
        }
        if running { decider.reset(physicalKeyDown: tap.isKeyDown(decider.hotkey.keycode)) }
        if !running { Log.hotkey.error("Event tap could not start; verify Input Monitoring permission") }
        return running
    }

    func stop() {
        if running { running = false; tap.stop() }
        decider.reset()
    }

    /// Keeps the installed tap running; cancels an outstanding hold on a change.
    func setHotkey(_ hotkey: Hotkey) {
        guard hotkey != decider.hotkey else { return }
        let wasActive = decider.active
        decider = HotkeyDecider(hotkey: hotkey)
        if running { decider.reset(physicalKeyDown: tap.isKeyDown(hotkey.keycode)) }
        if wasActive { onAction?(.cancel) }
    }

    private func handle(_ snapshot: HotkeyEventSnapshot) -> Bool {
        if snapshot.typeRawValue == CGEventType.tapDisabledByTimeout.rawValue
            || snapshot.typeRawValue == CGEventType.tapDisabledByUserInput.rawValue {
            // We cannot reconstruct missed down/up cycles. End the interrupted
            // action and synchronize the physical side before accepting more events.
            let wasActive = decider.active
            decider.reset(physicalKeyDown: tap.isKeyDown(decider.hotkey.keycode))
            tap.enable()
            Log.hotkey.notice("Event tap re-enabled after physical-key synchronization")
            if wasActive { onAction?(.cancel) }
            return false
        }
        let decision = decider.transition(snapshot, canCancel: canCancel?())
        if decision.action != .none { onAction?(decision.action) }
        return decision.suppress
    }
}

/// Installed exclusively on the main run loop; callback dispatch remains synchronous.
@MainActor
private final class SystemHotkeyTap: HotkeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var context: UnsafeMutableRawPointer?

    /// Retained explicitly for the entire tap lifetime. The handler weakly references
    /// its listener, so retaining this context cannot keep the listener alive.
    @MainActor
    private final class CallbackContext {
        let handler: @MainActor (HotkeyEventSnapshot) -> Bool
        init(handler: @escaping @MainActor (HotkeyEventSnapshot) -> Bool) { self.handler = handler }
    }

    isolated deinit { stop() }

    func start(handler: @escaping @MainActor (HotkeyEventSnapshot) -> Bool) -> Bool {
        if tap != nil { enable(); return true }
        let retainedContext = Unmanaged.passRetained(CallbackContext(handler: handler)).toOpaque()
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // The source is only attached to CFRunLoopGetMain(). No Task may
                // interleave these ordered transitions or outlive this callback.
                let suppress = MainActor.assumeIsolated {
                    let context = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
                    let snapshot = HotkeyEventSnapshot(
                        typeRawValue: type.rawValue,
                        keycode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                        flagsRawValue: event.flags.rawValue,
                        isAutoRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                        sourceUserData: event.getIntegerValueField(.eventSourceUserData)
                    )
                    return context.handler(snapshot)
                }
                return suppress ? nil : Unmanaged.passUnretained(event)
            }, userInfo: retainedContext
        ) else {
            Unmanaged<CallbackContext>.fromOpaque(retainedContext).release()
            return false
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            Unmanaged<CallbackContext>.fromOpaque(retainedContext).release()
            Log.hotkey.error("Could not create event tap run loop source")
            return false
        }
        tap = newTap
        source = newSource
        context = retainedContext
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        enable()
        return true
    }

    func enable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    func isKeyDown(_ keycode: UInt16) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: keycode)
    }

    func stop() {
        // Invalidate/remove the callback source before releasing its retained context.
        // Teardown and callbacks are serialized on the main actor/main run loop.
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if let context { Unmanaged<CallbackContext>.fromOpaque(context).release() }
        context = nil
    }
}
