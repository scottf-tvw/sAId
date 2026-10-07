import AppKit
import SwiftUI

/// Construct only in the app shell, never in presentation tests. Updating this panel
/// neither activates sAId nor takes focus from the application receiving dictation.
@MainActor
final class HUDPanel: NSPanel {
    private let hosting = NSHostingView(rootView: HUDView(presentation: HUDPresentation(DictationState())))
    private var presentationGeneration: UInt64 = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = hosting
    }
    func update(_ state: DictationState) {
        let presentation = HUDPresentation(state)
        presentationGeneration += 1
        let generation = presentationGeneration
        guard presentation.visible else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.presentationGeneration == generation else { return }
                    self.orderOut(nil)
                }
            }
            return
        }
        alphaValue = 1
        hosting.rootView = HUDView(presentation: presentation)
        // The primary pill stays 44pt. A separate 32pt notice sits above it,
        // preserving live capture/finalization when an independent error is shown.
        let height: CGFloat = presentation.notice == nil ? 44 : 82
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            setFrame(NSRect(x: frame.midX - 280, y: frame.minY + 32, width: 560, height: height), display: true)
        }
        orderFrontRegardless()
    }
}
