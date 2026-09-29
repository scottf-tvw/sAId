import Foundation

/// Owns one reducer lifetime. All external commands and asynchronous completions pass
/// through one mailbox; reentrancy while awaiting cleanup cannot reorder physical actions.
actor DictationController {
    private enum Command: Sendable {
        case hotkey(HotkeyAction, String?)
        case readiness(ModelReadiness)
        case configure((any CaptureSource)?, (any TextSink)?, PostProcess?)
        case enabled(Bool, String?)
        case progress(DictationSessionID)
        case preview(DictationSessionID)
        case event(DictationEvent)
        case shutdown
    }
    private struct Request: Sendable {
        let command: Command
        var completion: CheckedContinuation<Void, Never>?
    }
    private struct Session {
        let id: DictationSessionID
        let target: String?
        let timestamp: Date
        let source: any CaptureSource
        let postProcess: PostProcess
        let sink: any TextSink
        let buffer: DictationSessionBuffer
        var starting: Task<AsyncThrowingStream<[Float], Error>, Error>?
        var capture: Task<Void, Never>?
        var preview: Task<Void, Never>?
        var operation: Task<Void, Never>?
        var stoppedCapture = false
        var stoppedPreview = false
        var reportedSamples = 0
        var reportedPreviewFailure = false
    }
    private let requests: AsyncStream<Request>
    private nonisolated let input: AsyncStream<Request>.Continuation
    private var worker: Task<Void, Never>?
    private var session: Session?
    private var capture: any CaptureSource
    private let preview: any PreviewTranscriber
    private let final: any FinalTranscriber
    private var sink: any TextSink
    private var postProcess: PostProcess
    private let record: @Sendable (DictationHistoryEntry) async -> Void
    private let log: @Sendable (String) async -> Void
    private let delay: @Sendable (Duration) async throws -> Void
    private var timer: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<DictationState>.Continuation] = [:]
    private var pendingTarget: String?
    private var enabled = true
    private var closed = false
    private(set) var currentState = DictationState()

    init(capture: any CaptureSource, preview: any PreviewTranscriber, final: any FinalTranscriber,
         sink: any TextSink, postProcess: PostProcess = PostProcess(),
         record: @escaping @Sendable (DictationHistoryEntry) async -> Void = { _ in },
         log: @escaping @Sendable (String) async -> Void = { Log.app.info("\($0, privacy: .public)") },
         delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.capture = capture; self.preview = preview; self.final = final; self.sink = sink
        self.postProcess = postProcess; self.record = record; self.log = log; self.delay = delay
        let pair = AsyncStream<Request>.makeStream()
        requests = pair.stream; input = pair.continuation
    }

    /// Call synchronously from HotkeyListener's callback. Yield occurs before any Task
    /// is scheduled, so press/release order is the callback's physical order.
    nonisolated func send(_ action: HotkeyAction, target: String? = nil) { enqueue(.hotkey(action, target)) }
    nonisolated func handle(_ action: HotkeyAction, target: String? = nil) async { await request(.hotkey(action, target)) }
    nonisolated func setModelReadiness(_ value: ModelReadiness) async { await request(.readiness(value)) }
    nonisolated func configure(capture: (any CaptureSource)? = nil, sink: (any TextSink)? = nil, postProcess: PostProcess? = nil) async {
        await request(.configure(capture, sink, postProcess))
    }
    /// Enqueue UI settings before a subsequent physical press can overtake them.
    nonisolated func sendConfiguration(capture: (any CaptureSource)? = nil, sink: (any TextSink)? = nil, postProcess: PostProcess? = nil) {
        enqueue(.configure(capture, sink, postProcess))
    }
    nonisolated func setEnabled(_ value: Bool, reason: String? = nil) async { await request(.enabled(value, reason)) }
    /// Returns only after inference, capture, preview and insertion/clipboard cleanup.
    nonisolated func shutdown() async { await request(.shutdown) }

    func states() -> AsyncStream<DictationState> {
        let id = UUID()
        let pair = AsyncStream<DictationState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(currentState)
        if closed { pair.continuation.finish() }
        else {
            observers[id] = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish() { for observer in observers.values { observer.yield(currentState) } }
    private nonisolated func enqueue(_ command: Command) {
        input.yield(Request(command: command))
        Task { await startWorker() }
    }
    private nonisolated func request(_ command: Command) async {
        await withCheckedContinuation { completion in
            if case .terminated = input.yield(Request(command: command, completion: completion)) { completion.resume() }
            else { Task { await startWorker() } }
        }
    }
    private func startWorker() {
        guard worker == nil, !closed else { return }
        worker = Task { await run() }
    }
    private func run() async {
        for await request in requests {
            if !closed { await process(request.command) }
            request.completion?.resume()
        }
        worker = nil
    }
    private func process(_ command: Command) async {
        switch command {
        case .hotkey(let action, let target):
            switch action {
            case .pressed:
                guard enabled else { return }
                if !currentState.hotkeyHeld { pendingTarget = target }
                await apply(.hotkeyDown)
            case .released:
                if case .listening(let id, _, _) = currentState.phase { await drain(id); await reconcile(id) }
                await apply(.hotkeyUp)
            case .cancel:
                let cancelsWork = !currentState.queuedStart
                if cancelsWork { cancelTasks() }
                await apply(.cancel)
                if cancelsWork { await cancelOwnedWork() }
            case .none: break
            }
        case .readiness(let value):
            switch value {
            case .ready: await apply(.modelsReady)
            case .failed(let reason): await apply(.modelsFailed(reason))
            case .loading: await apply(.modelsLoading)
            }
        case .configure(let source, let replacementSink, let processing):
            if let source {
                if case .listening = currentState.phase { cancelTasks(); await apply(.cancel); await cancelOwnedWork() }
                capture = source
            }
            if let replacementSink { sink = replacementSink }
            if let processing { postProcess = processing }
        case .enabled(let value, let reason):
            enabled = value
            if !value {
                await abort()
                if let reason { await apply(.unavailable(reason)) }
            }
        case .progress(let id):
            guard session?.id == id, currentState.session == id else { return }
            if let buffer = session?.buffer,
               await buffer.sampleCount >= DictationSessionBuffer.sampleLimit { await drain(id) }
            await reconcile(id)
        case .preview(let id): await reconcilePreview(id)
        case .event(let event): await apply(event)
        case .shutdown:
            enabled = false
            await abort()
            timer?.cancel(); await timer?.value; timer = nil
            closed = true
            input.finish()
            for observer in observers.values { observer.finish() }
            observers.removeAll()
        }
    }

    private func apply(_ event: DictationEvent) async {
        // Capture the originating context before reducer effects can start a queued session.
        let context = session
        let (state, effects) = DictationReducer.reduce(currentState, event)
        currentState = state; publish()
        for effect in effects { await execute(effect, event: event, context: context) }
    }
    private func execute(_ effect: DictationEffect, event: DictationEvent, context: Session?) async {
        switch effect {
        case .startCapture(let id): await startCapture(id)
        case .startPreview(let id): startPreview(id)
        case .stopCapture(let id): await stopCapture(id)
        case .stopPreview(let id): await stopPreview(id)
        case .runFinal(let id): await runFinal(id)
        case .insert(let id, let text): insert(id, text: text)
        case .record(let text):
            guard let context else { return }
            let source: DictationHistoryEntry.Source
            let failure: String?
            switch event {
            case .engineFailed(_, let reason): source = .previewAfterFinalFailure; failure = reason
            case .insertFailed(_, let reason): source = .final; failure = reason
            case .finalText: source = .previewAfterFinalFailure; failure = "Model unavailable"
            default: source = .final; failure = nil
            }
            await record(DictationHistoryEntry(text: text, timestamp: context.timestamp,
                                              targetAppID: context.target, source: source, failure: failure))
        case .log(let message): await log(message)
        case .scheduleHide(let id, let seconds), .scheduleErrorClear(let id, let seconds):
            timer?.cancel(); await timer?.value
            let delay = delay
            timer = Task { [weak self] in
                do { try await delay(.seconds(seconds)); try Task.checkCancellation(); self?.enqueue(.event(.timerFired(id))) }
                catch { /* Cancellation invalidates this timer; reducer checks its identity too. */ }
            }
        }
    }
    private func startCapture(_ id: DictationSessionID) async {
        let source = capture, buffer = DictationSessionBuffer()
        session = Session(id: id, target: pendingTarget, timestamp: Date(), source: source,
                          postProcess: postProcess, sink: sink, buffer: buffer)
        let starting = Task { try await source.start() }
        session?.starting = starting
        session?.capture = Task { [weak self] in
            do {
                let stream = try await starting.value
                for try await chunk in stream {
                    if await buffer.append(chunk) { self?.enqueue(.progress(id)) }
                }
            } catch { await buffer.captureFailed("Microphone capture failed") }
            self?.enqueue(.progress(id))
        }
    }

    private func startPreview(_ id: DictationSessionID) {
        guard currentState.session == id, currentState.previewActive, let buffer = session?.buffer else { return }
        let preview = preview
        session?.preview = Task { [weak self] in
            do {
                let events = try await preview.start()
                // This child is always awaited before the preview worker returns.
                let observer = Task { [weak self] in
                    do {
                        for try await line in events {
                            await buffer.preview(line); self?.enqueue(.preview(id))
                        }
                    } catch { await buffer.previewFailed(String(describing: error)); self?.enqueue(.preview(id)) }
                }
                do { for await chunk in buffer.previewInput { try await preview.feed(chunk) } }
                catch { await buffer.previewFailed(String(describing: error)); self?.enqueue(.preview(id)) }
                await preview.stop()
                await observer.value
            } catch {
                await buffer.previewFailed(String(describing: error)); await preview.stop()
            }
            self?.enqueue(.preview(id))
        }
    }
    private func stopCapture(_ id: DictationSessionID) async {
        guard let context = session, context.id == id, !context.stoppedCapture else { return }
        session?.stoppedCapture = true
        // A source may still be installing its tap. Never let stop race ahead of start.
        _ = try? await context.starting?.value
        await context.source.stop()
        await context.capture?.value // Producer is quiescent; consume every buffered accepted chunk.
        await context.buffer.finishAudio()
    }
    private func stopPreview(_ id: DictationSessionID) async {
        guard let context = session, context.id == id, !context.stoppedPreview else { return }
        session?.stoppedPreview = true
        await context.buffer.finishAudio()
        await context.preview?.value
        await reconcilePreview(id)
    }
    private func drain(_ id: DictationSessionID) async {
        await stopCapture(id)
        await stopPreview(id)
    }
    private func reconcile(_ id: DictationSessionID) async {
        guard let context = session, context.id == id, currentState.session == id else { return }
        if let failure = await context.buffer.captureFailure {
            await apply(.captureFailed(session: id, reason: failure)); return
        }
        await reconcilePreview(id)
        let count = await context.buffer.sampleCount
        guard count > (session?.reportedSamples ?? 0),
              case .listening(_, _, let seconds) = currentState.phase else { return }
        session?.reportedSamples = count
        // Rebase on the integer sample count; summing fractional chunk durations can
        // round exactly 4000 samples below the short-tap threshold (or miss the cap).
        await apply(.audio(session: id, seconds: Double(count) / 16_000 - seconds))
    }
    private func reconcilePreview(_ id: DictationSessionID) async {
        // Stop may finish with an error after the reducer has left listening (or the
        // session entirely). The owned runtime still must report that error once.
        guard let context = session, context.id == id else { return }
        if let line = await context.buffer.latestPreview { await apply(.preview(session: id, line: line)) }
        if let failure = await context.buffer.previewFailure, !context.reportedPreviewFailure {
            session?.reportedPreviewFailure = true
            if currentState.previewActive { await apply(.previewFailed(session: id, reason: failure)) }
            else { await log("preview: \(failure)") }
        }
    }
    private func runFinal(_ id: DictationSessionID) async {
        guard let context = session, context.id == id, currentState.session == id else { return }
        let samples = await context.buffer.samples, final = final
        session?.operation = Task { [weak self] in
            do {
                let text = try await final.transcribe(samples)
                try Task.checkCancellation()
                self?.enqueue(.event(.finalText(session: id, text: context.postProcess.apply(text))))
            } catch is CancellationError { }
            catch { self?.enqueue(.event(.engineFailed(session: id, reason: String(describing: error)))) }
        }
    }
    private func insert(_ id: DictationSessionID, text: String) {
        guard let context = session, context.id == id else { return }
        let sink = context.sink
        session?.operation = Task { [weak self] in
            do {
                try await sink.insert(text); try Task.checkCancellation()
                self?.enqueue(.event(.inserted(session: id)))
            } catch is CancellationError { }
            catch {
                let message = (error as? TextInsertionError)?.userMessage ?? "Paste failed — copy from History"
                self?.enqueue(.event(.insertFailed(session: id, reason: message)))
            }
        }
    }
    private func cancelTasks() {
        session?.starting?.cancel()
        session?.preview?.cancel()
        session?.operation?.cancel()
    }
    private func cancelOwnedWork() async {
        guard let context = session else { return }
        context.operation?.cancel()
        await drain(context.id)
        await context.operation?.value
    }
    private func abort() async {
        // First cancel may only withdraw the queued key; the second ends the active job.
        cancelTasks()
        await apply(.cancel); await apply(.cancel)
        await cancelOwnedWork()
        await apply(.hotkeyUp)
    }
}
