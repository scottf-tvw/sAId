import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppViewModel()
    private var windows: [String: NSWindow] = [:]
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.showPermissions = { [weak self] in self?.showPermissions() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        model.start()
    }
    @objc private func systemDidWake(_ notification: Notification) { model.wake() }
    func applicationDidBecomeActive(_ notification: Notification) {
        model.recheckPermissions()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func showSettings() {
        model.refreshDevices()
        show("settings", title: "sAId Settings", size: NSSize(width: 660, height: 640), minimum: NSSize(width: 600, height: 500), view: SettingsView(model: model, settings: model.settings))
    }
    func showHistory() {
        show("history", title: "sAId History", size: NSSize(width: 640, height: 500), minimum: NSSize(width: 500, height: 320), view: HistoryView(store: model.history, copy: model.copy))
    }
    func showPermissions() {
        show("permissions", title: "sAId Permissions", size: NSSize(width: 620, height: 360), minimum: NSSize(width: 580, height: 320), view: PermissionsView(model: model))
        model.checklistVisibility(true)
    }
    private func show<Content: View>(_ id: String, title: String, size: NSSize, minimum: NSSize, view: Content) {
        if let window = windows[id] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = Self.makeWindow(id: id, title: title, size: size, minimum: minimum, view: view)
        window.delegate = self
        windows[id] = window; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Construction/layout is separate from presentation: SwiftUI's default ideal-size
    /// propagation can replace the initial rectangle while attaching the hosting controller.
    static func makeWindow<Content: View>(id: String, title: String, size: NSSize, minimum: NSSize, view: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.identifier = NSUserInterfaceItemIdentifier(id)
        let titleHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let visible = NSScreen.main?.visibleFrame.size ?? size
        let available = NSSize(width: max(1, visible.width - 24), height: max(1, visible.height - titleHeight - 24))
        let contentMinimum = NSSize(width: min(minimum.width, available.width), height: min(minimum.height, available.height))
        let hosting = NSHostingController(rootView: view.frame(minWidth: contentMinimum.width, minHeight: contentMinimum.height))
        // Keep minimum propagation, but opt out of ideal/max sizes replacing our geometry.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.contentMinSize = contentMinimum
        // Apply content geometry after attachment, without fixing the window to its ideal size.
        window.setContentSize(NSSize(width: min(size.width, available.width), height: min(size.height, available.height)))
        return window
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        if id == "permissions" { model.checklistVisibility(false) }
        windows[id] = nil
    }
}
