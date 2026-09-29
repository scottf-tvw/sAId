import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var settings: SettingsStore
    @State private var confirmReset = false
    @State private var filler = ""
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "slider.horizontal.3") }
            CorrectionsView(settings: settings).tabItem { Label("Corrections", systemImage: "text.badge.checkmark") }
            processing.tabItem { Label("Text", systemImage: "textformat") }
            modelSettings.tabItem { Label("Model", systemImage: "waveform") }
        }.padding(16)
        .alert("Could not save change", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: { Text(model.actionError ?? "") }
    }
    private func preference<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { settings.preferences[keyPath: keyPath] }, set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } })
    }
    private var general: some View {
        Form {
            if let error = settings.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Recover preferences (archive damaged file)") { do { try settings.recoverPreferences() } catch { model.actionError = error.localizedDescription } }
            }
            Toggle("Enable dictation", isOn: preference(\.enabled))
            Picker("Hold to dictate", selection: preference(\.hotkey)) { ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) } }
            Text("Hold the key while speaking; release to insert. Escape cancels.").font(.caption).foregroundStyle(.secondary)
            Picker("Microphone", selection: preference(\.inputDeviceUID)) {
                Text("System default").tag("")
                ForEach(model.devices) { Text($0.name).tag($0.id) }
                if !settings.preferences.inputDeviceUID.isEmpty && !model.devices.contains(where: { $0.id == settings.preferences.inputDeviceUID }) {
                    Text("Selected microphone unavailable").tag(settings.preferences.inputDeviceUID)
                }
            }
            Button("Refresh microphones", action: model.refreshDevices)
            Text("Changing microphones ends an active recording. Text rules apply to the next dictation.").font(.caption).foregroundStyle(.secondary)
            Picker("Insert text using", selection: preference(\.insertionStrategy)) {
                Text("Clipboard paste (restores clipboard)").tag(TextInsertionStrategy.clipboardPaste)
                Text("Direct Unicode typing").tag(TextInsertionStrategy.directUnicode)
            }
            Text("Insertion strategy changes apply to the next dictation.").font(.caption).foregroundStyle(.secondary)
            Button("Permissions…") { model.showPermissions?() }
        }.formStyle(.grouped)
    }
    private var processing: some View {
        Form {
            Toggle("Remove filler phrases", isOn: preference(\.removeFillers))
            Text("Built-in phrases: um, uh, er, hmm, you know").font(.caption).foregroundStyle(.secondary)
            Section("Additional filler phrases") {
                ForEach(Array(settings.preferences.customFillers.enumerated()), id: \.offset) { index, phrase in
                    HStack { Text(phrase); Spacer(); Button("Delete", role: .destructive) { model.updatePreferences { $0.customFillers.remove(at: index) } } }
                }
                HStack {
                    TextField("New phrase", text: $filler)
                    Button("Add") {
                        let value = filler.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        model.updatePreferences { $0.customFillers.append(value) }; filler = ""
                    }.disabled(filler.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Toggle("Add a trailing space", isOn: preference(\.trailingSpace))
        }.formStyle(.grouped)
    }
    private var modelSettings: some View {
        Form {
            Text("Moonshine · English Medium Streaming").font(.headline)
            Text(model.model.detail).textSelection(.enabled)
            if model.model.readiness == .loading { ProgressView(value: model.model.progress) }
            Text("One on-device model serves preview and final transcription and stays loaded while sAId is open.").foregroundStyle(.secondary)
            LabeledContent("Cache") { Text(defaultModelRoot.path).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Retry model", action: model.retryModel).disabled(!model.canRetry)
                Button("Show cache in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: defaultModelRoot.path) }
                Button("Reset model cache…", role: .destructive) { confirmReset = true }.disabled(!model.canReset)
            }
            Text("Reset is available while idle and after loading finishes. It removes only sAId’s model cache and downloads a fresh copy.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
        .confirmationDialog("Reset sAId’s model cache?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset model cache", role: .destructive) { Task { await model.resetModel() } }
        } message: { Text("The resident model will be released and this app’s cached model files removed. A download is required before dictation can resume. History and corrections are kept.") }
    }
}

private struct CorrectionsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var editing: Int?
    @State private var source = ""
    @State private var replacement = ""
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whole-word corrections").font(.headline)
            Text("Matching ignores case. Replacement spelling and capitalization are preserved.").font(.caption).foregroundStyle(.secondary)
            if let error = settings.correctionsError { Text(error).foregroundStyle(.orange) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            List {
                ForEach(Array(settings.corrections.enumerated()), id: \.offset) { index, correction in
                    HStack {
                        Text(correction.from); Image(systemName: "arrow.right"); Text(correction.to).bold(); Spacer()
                        Button("Edit") { editing = index; source = correction.from; replacement = correction.to }
                        Button("Delete", role: .destructive) {
                            perform { var next = settings.corrections; next.remove(at: index); try settings.replaceCorrections(next); cancelEdit() }
                        }
                    }
                }
            }
            HStack {
                TextField("Heard phrase", text: $source)
                TextField("Replacement", text: $replacement)
                Button(editing == nil ? "Add" : "Save") {
                    perform {
                        var next = settings.corrections
                        let value = Correction(from: source, to: replacement)
                        if let editing, next.indices.contains(editing) { next[editing] = value } else { next.append(value) }
                        try settings.replaceCorrections(next); cancelEdit()
                    }
                }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editing != nil { Button("Cancel", action: cancelEdit) }
            }
            Text("Import replaces the current list after validation. An empty list disables corrections.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Import JSON…", action: importJSON)
                Button("Export JSON…", action: exportJSON)
                Spacer()
                Text("\(settings.corrections.count) rules").foregroundStyle(.secondary)
            }
        }.padding(12)
    }
    private func cancelEdit() { editing = nil; source = ""; replacement = "" }
    private func perform(_ action: () throws -> Void) { do { try action(); errorMessage = nil } catch { errorMessage = error.localizedDescription } }
    private func importJSON() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try settings.importCorrections(Data(contentsOf: url)); cancelEdit() }
    }
    private func exportJSON() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "said-corrections.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try settings.exportCorrections().write(to: url, options: .atomic) }
    }
}
