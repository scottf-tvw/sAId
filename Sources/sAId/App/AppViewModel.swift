import SaidEngine
import AppKit
import Combine

/// Owns the sole engine/controller and stores for the entire app lifetime.
@MainActor
final class AppViewModel: ObservableObject {
    let settings: SettingsStore
    let history: HistoryStore
    @Published private(set) var permissions = PermissionStatus.unknown
    @Published private(set) var model = ModelStatus()
    @Published private(set) var state = DictationState()
    @Published private(set) var restartRequired = false
    @Published private(set) var loadingModel = false
    @Published private(set) var transitionInProgress = false
    @Published private(set) var tapError: String?
    @Published private(set) var devices: [MicrophoneDevice] = []
    @Published var actionError: String?
    var showPermissions: (() -> Void)?
    private var engine: MoonshineEngine
    private var controller: DictationController
    private var inserter: TextInserter
    private let hotkey: HotkeyListener
    private let hud: HUDPanel
    private var stateTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var checklistTask: Task<Void, Never>?
    private var configurationGeneration: UInt64 = 0
    private var acceptingHotkeys = false
    private var reconfiguringHotkey = false
    private var started = false
    private var closed = false
    private var appliedPreferences: AppPreferences

    init() {
        let settings = SettingsStore(), history = HistoryStore(), engine = MoonshineEngine()
        let inserter = TextInserter(strategy: settings.preferences.insertionStrategy)
        self.settings = settings; self.history = history; self.engine = engine; self.inserter = inserter
        appliedPreferences = settings.preferences
        hotkey = HotkeyListener(hotkey: settings.preferences.hotkey.hotkey)
        hud = HUDPanel()
        controller = Self.makeController(engine: engine, inserter: inserter, settings: settings, history: history)
        settings.onChange = { [weak self] in self?.applySettings() }
        hotkey.canCancel = { [weak self] in
            guard let self, !self.closed, !self.reconfiguringHotkey, self.acceptingHotkeys else { return false }
            return self.controller.canCancel
        }
        hotkey.onAction = { [weak self] action in
            guard let self, !self.closed, !self.reconfiguringHotkey else { return }
            self.recheckPermissions()
            guard self.acceptingHotkeys else { return }
            // Yield in the callback itself; no per-edge Task can reorder release/press.
            HotkeyControllerBridge.send(action, to: self.controller,
                                        target: action == .pressed ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil)
        }
    }
    private static func makeController(engine: MoonshineEngine, inserter: TextInserter, settings: SettingsStore, history: HistoryStore) -> DictationController {
        DictationController(capture: AudioCapture(inputDeviceUID: settings.preferences.inputDeviceUID),
                            preview: engine, final: engine, sink: inserter, postProcess: settings.postProcess,
                            record: { entry in await history.record(entry) })
    }
    var canDictate: Bool {
        AppReadiness(enabled: settings.preferences.enabled, permissions: permissions, model: model.readiness).canDictate && !transitionInProgress && !restartRequired && tapError == nil
    }
    var canReset: Bool { !closed && !restartRequired && !transitionInProgress && !loadingModel && state.session == nil }
    var canRetry: Bool { if case .failed = model.readiness { return canReset }; return false }
    var statusText: String {
        if !settings.preferences.enabled { return "Dictation off" }
        if !permissions.allGranted { return "Permissions required" }
        if let tapError { return tapError }
        return model.detail
    }
    func start() {
        guard !started else { return }; started = true
        observeController(); hud.update(state)
        refreshDevices(); recheckPermissions(force: true); loadModel()
    }
    func refreshDevices() { devices = Microphones.available() }
    func wake() {
        guard !closed else { return }
        acceptingHotkeys = false; hotkey.stop()
        let controller = controller, source = AudioCapture(inputDeviceUID: settings.preferences.inputDeviceUID)
        enqueueConfiguration {
            await controller.configure(capture: source)
            await controller.handle(.released) // Missed physical releases cannot leave a hold stuck.
        }
        refreshDevices(); recheckPermissions(force: true)
    }
    func updatePreferences(_ change: (inout AppPreferences) -> Void) {
        var value = settings.preferences; change(&value)
        do { try settings.update(value) } catch { actionError = error.localizedDescription }
    }
    private func applySettings() {
        let next = settings.preferences, previous = appliedPreferences
        appliedPreferences = next
        let hotkeyChanged = next.hotkey != previous.hotkey
        if hotkeyChanged {
            // A settings edit must not cancel finalization after the audio cap.
            // Reconfiguration below cancels only capture, then clears the old hold.
            reconfiguringHotkey = true
            hotkey.setHotkey(next.hotkey.hotkey)
            reconfiguringHotkey = false
        }
        var replacementSink: TextInserter?
        if next.insertionStrategy != previous.insertionStrategy {
            inserter = TextInserter(strategy: next.insertionStrategy)
            replacementSink = inserter
        }
        let processing = settings.postProcess
        let capture: AudioCapture? = (next.inputDeviceUID != previous.inputDeviceUID || hotkeyChanged) ? AudioCapture(inputDeviceUID: next.inputDeviceUID) : nil
        controller.sendConfiguration(capture: capture, sink: replacementSink, postProcess: processing)
        if hotkeyChanged { controller.send(.released) }
        reconcileAvailability()
    }
    private func enqueueConfiguration(_ operation: @escaping @MainActor () async -> Void) {
        let previous = configurationTask
        configurationTask = Task { await previous?.value; guard !self.closed else { return }; await operation() }
    }
    private func observeController() {
        stateTask?.cancel()
        let controller = controller
        stateTask = Task { [weak self] in
            for await state in await controller.states() {
                guard !Task.isCancelled, let self else { return }
                self.state = state; self.hud.update(state)
                if case .failed(let reason) = state.readiness, self.model.readiness == .ready {
                    self.model.finish(.failed(reason), generation: self.model.generation)
                    self.reconcileAvailability()
                }
            }
        }
    }
    func recheckPermissions(force: Bool = false) {
        guard !closed else { return }
        let latest = SystemPermissions.check()
        guard force || latest != permissions else { return }
        permissions = latest
        if !latest.allGranted { showPermissions?() }
        else { checklistTask?.cancel(); checklistTask = nil }
        reconcileAvailability()
    }
    func checklistVisibility(_ visible: Bool) {
        checklistTask?.cancel(); checklistTask = nil
        guard visible, !permissions.allGranted, !closed else { return }
        checklistTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.recheckPermissions()
                if self.permissions.allGranted { return }
            }
        }
    }
    func requestPermission(_ permission: PermissionKind) async {
        await SystemPermissions.request(permission); recheckPermissions(force: true)
    }
    private func reconcileAvailability() {
        guard !closed else { return }
        configurationGeneration += 1
        let generation = configurationGeneration
        let enabled = AppReadiness(enabled: settings.preferences.enabled, permissions: permissions, model: model.readiness).canDictate && !transitionInProgress && !restartRequired
        if !enabled { acceptingHotkeys = false; hotkey.stop(); controller.send(.cancel) }
        let reason = permissions.allGranted ? nil : "Permissions required — open the checklist"
        let controller = controller
        enqueueConfiguration { [weak self] in
            await controller.setEnabled(enabled, reason: enabled ? nil : reason)
            guard let self, generation == self.configurationGeneration, !self.closed else { return }
            if enabled {
                let started = self.hotkey.start()
                self.acceptingHotkeys = started
                self.tapError = started ? nil : "Hotkey unavailable — recheck permissions"
                if !started { await controller.setEnabled(false); self.showPermissions?() }
            }
        }
        // This is separate from visible-checklist polling: Input Monitoring loss
        // may prevent ANY further callback, so the enabled app must check independently.
        if settings.preferences.enabled, healthTask == nil {
            healthTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self else { return }; self.recheckPermissions()
                }
            }
        } else if !settings.preferences.enabled { healthTask?.cancel(); healthTask = nil }
    }
    func retryModel() { guard canRetry else { return }; loadModel() }
    private func loadModel() {
        guard modelTask == nil, !closed else { return }
        loadingModel = true
        let generation = model.begin(), engine = engine, controller = controller
        reconcileAvailability()
        modelTask = Task { [weak self] in
            await controller.setModelReadiness(.loading)
            do {
                try await engine.load { [weak self] fraction, message in
                    Task { @MainActor [weak self] in self?.model.update(progress: fraction, detail: message, generation: generation) }
                }
                try Task.checkCancellation()
                guard let self, generation == self.model.generation, !self.closed else { return }
                self.model.finish(.ready, generation: generation)
                await controller.setModelReadiness(.ready)
            } catch {
                guard let self, generation == self.model.generation, !self.closed else { return }
                Log.engine.error("Model load failed: \(String(describing: error), privacy: .public)")
                let message = "Model unavailable. Check the connection or cache, then Retry."
                self.model.finish(.failed(message), generation: generation)
                await controller.setModelReadiness(.failed(message))
            }
            guard let self, generation == self.model.generation else { return }
            self.modelTask = nil; self.loadingModel = false; self.reconcileAvailability()
        }
    }
    func resetModel() async {
        guard canReset else { return }
        transitionInProgress = true; acceptingHotkeys = false; hotkey.stop()
        _ = model.begin() // Invalidate old progress callbacks before any await.
        await configurationTask?.value
        await controller.shutdown()
        stateTask?.cancel(); await stateTask?.value; stateTask = nil
        do {
            try await engine.releaseForExplicitReset()
        } catch {
            // Never create a second native model when releasing ownership failed.
            restartRequired = true; transitionInProgress = false
            let message = "Model could not be released. Quit and reopen sAId before dictating."
            model.finish(.failed(message), generation: model.generation); actionError = message
            Log.engine.error("Explicit native release failed: \(String(describing: error), privacy: .public)")
            return
        }
        do { try AppModelCache.removeOwnedCache() }
        catch {
            actionError = "The model cache could not be reset. Check folder access; no other app data was removed."
            Log.engine.error("Explicit model reset failed: \(String(describing: error), privacy: .public)")
        }
        guard !closed else { return }
        engine = MoonshineEngine()
        controller = Self.makeController(engine: engine, inserter: inserter, settings: settings, history: history)
        state = DictationState(); transitionInProgress = false
        observeController(); loadModel()
    }
    func shutdown() async {
        guard !closed else { return }; closed = true
        acceptingHotkeys = false; hotkey.stop(); healthTask?.cancel(); checklistTask?.cancel()
        modelTask?.cancel(); await modelTask?.value; modelTask = nil; loadingModel = false
        await configurationTask?.value
        await controller.shutdown()
        stateTask?.cancel(); await stateTask?.value
        try? await engine.releaseForExplicitReset()
        hud.orderOut(nil)
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func copyDiagnostics() {
        // Deliberately enumerate safe fields; never serialize state/history/errors or corrections.
        let modelStatus: String
        switch model.readiness { case .ready: modelStatus = "ready"; case .loading: modelStatus = "loading"; case .failed: modelStatus = "failed" }
        let diagnostics = "sAId \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nArchitecture: arm64\nMoonshine: 0.1.5 / mediumStreaming\nModel: \(modelStatus)\nEnabled: \(settings.preferences.enabled)\nMicrophone: \(permissions.microphone)\nInput Monitoring: \(permissions.inputMonitoring)\nAccessibility: \(permissions.accessibility)\nHotkey: \(settings.preferences.hotkey.label)\nInsertion: \(settings.preferences.insertionStrategy.rawValue)\nHistory entries: \(history.entries.count)"
        let controller = controller
        Task {
            let timing = await controller.latestTiming
            let security = TextInserter.latestSecurityCheck?.diagnosticText ?? "Last insertion security: none"
            copy(diagnostics + "\n" + security + "\n" + (timing?.diagnosticText ?? "Last session timing: none"))
        }
    }
}
