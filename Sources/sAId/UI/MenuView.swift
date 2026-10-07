import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var history: HistoryStore
    let showHistory: () -> Void
    let showSettings: () -> Void
    let showPermissions: () -> Void
    var body: some View {
        Toggle("Dictation on", isOn: Binding(get: { settings.preferences.enabled }, set: { value in model.updatePreferences { $0.enabled = value } }))
        Text(model.statusText).font(.caption)
        if let error = model.actionError {
            Text(error).font(.caption)
            Button("Resolve in Settings…", action: showSettings)
            Button("Dismiss error") { model.actionError = nil }
        }
        if !model.permissions.allGranted || model.tapError != nil { Button("Permissions…", action: showPermissions) }
        if model.canRetry { Button("Retry model", action: model.retryModel) }
        Divider()
        Button("Copy last transcript") { if let text = history.entries.first?.text { model.copy(text) } }.disabled(history.entries.isEmpty)
        Button("History…", action: showHistory)
        Button("Settings…", action: showSettings).keyboardShortcut(",")
        Button("Copy diagnostics", action: model.copyDiagnostics)
        Divider()
        Button("Quit sAId") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MenuStatusLabel: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var settings: SettingsStore
    private var symbol: String {
        if !settings.preferences.enabled { return "mic.slash" }
        if !model.permissions.allGranted || model.tapError != nil { return "exclamationmark.triangle.fill" }
        if model.model.readiness == .loading { return "arrow.triangle.2.circlepath" }
        if case .failed = model.model.readiness { return "exclamationmark.triangle.fill" }
        switch model.state.phase {
        case .listening: return "mic.fill"
        case .finalizing, .inserting: return "ellipsis.circle"
        default: return "mic"
        }
    }
    var body: some View {
        Image(systemName: symbol)
            .renderingMode(.original)
            .foregroundStyle(symbol == "exclamationmark.triangle.fill" ? Color.orange : Color.primary)
            .accessibilityLabel("sAId: \(model.statusText)")
    }
}
