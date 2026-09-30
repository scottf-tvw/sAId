import Foundation
import Synchronization

protocol CaptureSource: Sendable {
    func start() async throws -> AsyncThrowingStream<[Float], Error>
    /// Ends production after accepted chunks are yielded. The caller must drain its consumer.
    func stop() async
}

enum AudioCaptureError: Error, Sendable, Equatable {
    case alreadyRunning
    case deviceUnavailable
    case configurationChanged
    case systemWoke
    case invalidFormat
    case conversionFailed
    case coreAudio(OSStatus)
}

protocol AudioCaptureBackend: Sendable {
    func start(deviceUID: String, onSamples: @escaping @Sendable ([Float]) -> Void,
               onInterruption: @escaping @Sendable (AudioCaptureError) -> Void) async throws
    /// Quiesces all callbacks before returning.
    func stop() async
}

/// The delivery lock serializes acceptance and termination independently of actor scheduling.
/// A backend interruption closes acceptance immediately; termination waits for backend quiescence.
private final class CaptureDelivery: Sendable {
    private struct State {
        let continuation: AsyncThrowingStream<[Float], Error>.Continuation
        var error: (any Error)?
        var finished = false
    }
    private let state: Mutex<State>
    init(_ continuation: AsyncThrowingStream<[Float], Error>.Continuation) {
        state = Mutex(State(continuation: continuation))
    }
    func yield(_ samples: [Float]) {
        state.withLock { state in
            guard !state.finished, state.error == nil, !samples.isEmpty else { return }
            state.continuation.yield(samples)
        }
    }
    func fail(_ error: any Error) {
        state.withLock { state in if state.error == nil { state.error = error } }
    }
    func finish() {
        state.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            state.continuation.finish(throwing: state.error)
        }
    }
}

actor AudioCapture: CaptureSource {
    private struct Session {
        let id: UUID
        let backend: any AudioCaptureBackend
        let delivery: CaptureDelivery
        let starting: Task<Void, Error>
        var stopping: Task<Void, Never>?
    }
    private var session: Session?
    private let inputDeviceUID: String
    private let backendFactory: @Sendable () -> any AudioCaptureBackend

    init(inputDeviceUID: String = "",
         backendFactory: @escaping @Sendable () -> any AudioCaptureBackend = { SystemAudioBackend() }) {
        self.inputDeviceUID = inputDeviceUID
        self.backendFactory = backendFactory
    }

    func start() async throws -> AsyncThrowingStream<[Float], Error> {
        guard session == nil else { throw AudioCaptureError.alreadyRunning }
        let id = UUID()
        let backend = backendFactory()
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let delivery = CaptureDelivery(continuation)
        let deviceUID = inputDeviceUID
        let starting = Task {
            try await backend.start(deviceUID: deviceUID, onSamples: { delivery.yield($0) },
                                    onInterruption: { [weak self] error in
                delivery.fail(error)
                Task { await self?.stop(sessionID: id) }
            })
        }
        session = Session(id: id, backend: backend, delivery: delivery, starting: starting)
        do {
            try await withTaskCancellationHandler {
                try await starting.value
                try Task.checkCancellation()
            } onCancel: { [weak self] in Task { await self?.stop(sessionID: id) } }
            return stream
        } catch {
            delivery.fail(error)
            await stop(sessionID: id)
            throw error
        }
    }

    func stop() async {
        guard let id = session?.id else { return }
        await stop(sessionID: id)
    }

    private func stop(sessionID id: UUID) async {
        guard var current = session, current.id == id else { return }
        let stopping: Task<Void, Never>
        if let existing = current.stopping { stopping = existing }
        else {
            let backend = current.backend
            let delivery = current.delivery
            let starting = current.starting
            stopping = Task {
                // Stop must wait for an in-flight start, even when start fails or is cancelled.
                // Otherwise it could remove a tap before a suspended start later installs it.
                do { try await starting.value } catch { delivery.fail(error) }
                await backend.stop()
            }
            current.stopping = stopping
            session = current
        }
        await stopping.value
        if session?.id == id { session = nil }
        // Publish termination only after the actor can accept a new press.
        current.delivery.finish()
    }
}
