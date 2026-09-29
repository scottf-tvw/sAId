// REFERENCE ONLY — not compiled.
// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
// Extracted from TVWIT/hAIvd-Assist commit 5b0f9a7, sidecar/Sources/HaiveSpeechSidecar/main.swift,
// region "Hotkey listener" (lines 1733-1992). Adapt into sAId modules; keep this notice on derived files.

// MARK: - Hotkey listener
//
// Global event tap on the keyDown / keyUp / flagsChanged stream.
// Right Option is a modifier so it doesn't fire keyDown — we watch
// flagsChanged and diff the .option flag.

private struct HotkeyEventSnapshot: Sendable {
    let typeRawValue: UInt32
    let keycode: CGKeyCode
    let flagsRawValue: UInt64
    let isAutoRepeat: Bool

    var flags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }
}

private enum HotkeyTransitionAction: Equatable, Sendable {
    case press
    case release
    case cancel
}

private struct HotkeyTransitionResult: Equatable, Sendable {
    let suppress: Bool
    let actions: [HotkeyTransitionAction]

    static let pass = HotkeyTransitionResult(suppress: false, actions: [])
    static let suppressOnly = HotkeyTransitionResult(suppress: true, actions: [])
}

private struct HotkeyTransitionState {
    private var hotkeyModifierDown = false
    private var toggleActive = false
    private var suppressEscapeKeyUp = false

    mutating func resetAll() {
        hotkeyModifierDown = false
        toggleActive = false
        suppressEscapeKeyUp = false
    }

    mutating func resetToggleState() {
        toggleActive = false
    }

    mutating func transition(
        for event: HotkeyEventSnapshot,
        hotkey: HotkeyChoice,
        triggerMode: TriggerMode,
        isRecording: Bool
    ) -> HotkeyTransitionResult {
        if event.keycode == ESCAPE_KEYCODE {
            return transitionEscape(for: event, isRecording: isRecording)
        }

        guard event.keycode == hotkey.keycode else { return .pass }

        // Modifier masks are side-agnostic, so the physical keycode's
        // own down state is the source of truth for right-side releases.
        var isPress = false
        var isRelease = false
        if hotkey.isModifier {
            guard event.typeRawValue == CGEventType.flagsChanged.rawValue,
                  let mask = hotkey.modifierFlag else { return .suppressOnly }
            if hotkeyModifierDown {
                isRelease = true
                hotkeyModifierDown = false
            } else if event.flags.contains(mask) {
                isPress = true
                hotkeyModifierDown = true
            }
        } else {
            if event.typeRawValue == CGEventType.keyDown.rawValue, !event.isAutoRepeat {
                isPress = true
            } else if event.typeRawValue == CGEventType.keyUp.rawValue {
                isRelease = true
            } else {
                return .suppressOnly
            }
        }

        switch triggerMode {
        case .hold:
            var actions: [HotkeyTransitionAction] = []
            if isPress { actions.append(.press) }
            if isRelease { actions.append(.release) }
            return HotkeyTransitionResult(suppress: true, actions: actions)
        case .toggle:
            // Toggle mode: every press flips between "start recording"
            // and "stop recording". Releases are no-ops.
            guard isPress else { return .suppressOnly }
            let action: HotkeyTransitionAction = toggleActive ? .release : .press
            toggleActive.toggle()
            return HotkeyTransitionResult(suppress: true, actions: [action])
        }
    }

    private mutating func transitionEscape(
        for event: HotkeyEventSnapshot,
        isRecording: Bool
    ) -> HotkeyTransitionResult {
        if event.typeRawValue == CGEventType.keyDown.rawValue {
            if event.isAutoRepeat, suppressEscapeKeyUp {
                return .suppressOnly
            }
            guard isRecording else { return .pass }
            suppressEscapeKeyUp = true
            return event.isAutoRepeat
                ? .suppressOnly
                : HotkeyTransitionResult(suppress: true, actions: [.cancel])
        }

        if event.typeRawValue == CGEventType.keyUp.rawValue, suppressEscapeKeyUp {
            suppressEscapeKeyUp = false
            return .suppressOnly
        }

        return .pass
    }
}

@MainActor
final class HotkeyListener {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var transitionState = HotkeyTransitionState()

    /// User's current hotkey (set via Settings → Hotkey submenu).
    var hotkey: HotkeyChoice = hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
    var triggerMode: TriggerMode = .hold

    /// onPress fires when a recording should start (press in hold mode,
    /// or first press in toggle mode). onRelease fires when it should
    /// stop (release in hold mode, or second press in toggle mode).
    /// onCancel fires for Escape while a recording is active.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var isRecordingActive: (() -> Bool)?

    @discardableResult
    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
                let snapshot = HotkeyEventSnapshot(
                    typeRawValue: type.rawValue,
                    keycode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    flagsRawValue: event.flags.rawValue,
                    isAutoRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                let shouldSuppress = MainActor.assumeIsolated {
                    listener.handleTapCallback(snapshot)
                }
                return shouldSuppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            log("CGEvent.tapCreate failed — Input Monitoring permission missing?")
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("HotkeyListener: tap active (watching \(hotkey.name))")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        transitionState.resetAll()
    }

    /// Replace the current hotkey choice. Safe to call at runtime —
    /// the tap stays bound, only the per-event filter changes.
    func setHotkey(_ choice: HotkeyChoice) {
        self.hotkey = choice
        self.transitionState.resetAll()
        log("HotkeyListener: hotkey changed → \(choice.name)")
    }

    func setTriggerMode(_ mode: TriggerMode) {
        // Reset toggle state when switching modes so we don't get
        // stuck in mid-toggle from a previous session.
        if mode != triggerMode { transitionState.resetToggleState() }
        triggerMode = mode
        log("HotkeyListener: trigger mode → \(mode.rawValue)")
    }

    private func handleTapCallback(_ event: HotkeyEventSnapshot) -> Bool {
        if event.typeRawValue == CGEventType.tapDisabledByTimeout.rawValue
            || event.typeRawValue == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log("HotkeyListener: event tap re-enabled after \(event.typeRawValue)")
            }
            return false
        }

        let result = transitionState.transition(for: event,
                                                hotkey: hotkey,
                                                triggerMode: triggerMode,
                                                isRecording: isRecordingActive?() ?? false)
        dispatchHotkeyActions(result.actions)
        return result.suppress
    }

    private func dispatchHotkeyActions(_ actions: [HotkeyTransitionAction]) {
        guard !actions.isEmpty else { return }

        Task { @MainActor [weak self] in
            self?.performHotkeyActions(actions)
        }
    }

    private func performHotkeyActions(_ actions: [HotkeyTransitionAction]) {
        for action in actions {
            switch action {
            case .press: onPress?()
            case .release: onRelease?()
            case .cancel: onCancel?()
            }
        }
    }

    /// Called when the recording stops via a path other than the
    /// hotkey (auto-release at max duration, app quitting, etc.) so
    /// toggle mode doesn't end up offset by one.
    func resetToggleState() {
        transitionState.resetToggleState()
    }
}

