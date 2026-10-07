/// Synchronous app boundary: these mailbox writes execute in physical callback
/// order, never inside separate Tasks. The listener owns physical key suppression.
enum HotkeyControllerBridge {
    static func send(_ action: HotkeyAction, to controller: DictationController, target: String? = nil) {
        controller.send(action, target: target)
        // Escape or a tap reset makes the listener hold inactive, so it may
        // never emit its physical up action. Reset only controller bookkeeping;
        // the decider still prevents a new press until the key is released.
        if action == .cancel { controller.send(.released) }
    }
}
