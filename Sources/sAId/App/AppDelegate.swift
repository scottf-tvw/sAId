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
        show("settings", title: "sAId Settings", size: NSSize(width: 660, height: 640), view: SettingsView(model: model, settings: model.settings))
    }
    func showHistory() {
        show("history", title: "sAId History", size: NSSize(width: 640, height: 500), view: HistoryView(store: model.history, copy: model.copy))
    }
    func showPermissions() {
        show("permissions", title: "sAId Permissions", size: NSSize(width: 550, height: 360), view: PermissionsView(model: model))
        model.checklistVisibility(true)
    }
    private func show<Content: View>(_ id: String, title: String, size: NSSize, view: Content) {
        if let window = windows[id] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.identifier = NSUserInterfaceItemIdentifier(id)
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: min(size.width, 500), height: 320)
        windows[id] = window; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        if id == "permissions" { model.checklistVisibility(false) }
        windows[id] = nil
    }
}
