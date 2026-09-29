import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization

/// The callback and shutdown gate share checked isolation. Closing waits for conversion
/// and delivery already inside the gate, then rejects any late engine callbacks.
final class AudioTapProcessor: Sendable {
    private let converter: Mutex<PCMConverter?>
    private let onSamples: @Sendable ([Float]) -> Void
    private let onInterruption: @Sendable (AudioCaptureError) -> Void

    init(converter: PCMConverter, onSamples: @escaping @Sendable ([Float]) -> Void,
         onInterruption: @escaping @Sendable (AudioCaptureError) -> Void) {
        self.converter = Mutex(converter)
        self.onSamples = onSamples
        self.onInterruption = onInterruption
    }
    // Form the closure outside every actor so AVFoundation never inherits a Swift executor.
    var tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in process(buffer) }
    }
    func process(_ buffer: AVAudioPCMBuffer) {
        converter.withLock { converter in
            guard let converter else { return }
            do {
                let samples = try converter.convert(buffer: PCMConverter.copy(buffer))
                if !samples.isEmpty { onSamples(samples) }
            } catch { onInterruption(.conversionFailed) }
        }
    }
    func close() {
        converter.withLock { value in
            guard let converter = value else { return }
            do {
                let tail = try converter.drain()
                if !tail.isEmpty { onSamples(tail) }
            } catch { onInterruption(.conversionFailed) }
            value = nil
        }
    }
}

private final class CaptureObservers: Sendable {
    private struct Observation {
        let center: NotificationCenter
        let token: any NSObjectProtocol
    }
    private let observations = Mutex<[Observation]>([])

    func observe(center: NotificationCenter, name: Notification.Name, objectID: ObjectIdentifier? = nil,
                 callback: @escaping @Sendable () -> Void) {
        observations.withLock { observations in
            let token = center.addObserver(forName: name, object: nil, queue: nil) { notification in
                if let objectID {
                    guard let object = notification.object as AnyObject?, ObjectIdentifier(object) == objectID else { return }
                }
                callback()
            }
            observations.append(Observation(center: center, token: token))
        }
    }
    func removeAll() {
        observations.withLock { observations in
            for observation in observations { observation.center.removeObserver(observation.token) }
            observations.removeAll()
        }
    }
    deinit { removeAll() }
}

/// AVAudioEngine remains actor owned. The tap is a nonisolated Sendable closure and
/// performs only bounded PCM conversion/delivery, with no inference or MainActor hop.
actor SystemAudioBackend: AudioCaptureBackend {
    private var engine: AVAudioEngine?
    private var processor: AudioTapProcessor?
    private let observers = CaptureObservers()
    private var tapInstalled = false

    func start(deviceUID: String, onSamples: @escaping @Sendable ([Float]) -> Void,
               onInterruption: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        if !deviceUID.isEmpty {
            let device = try Self.resolveDevice(uid: deviceUID)
            guard let unit = input.audioUnit else { throw AudioCaptureError.deviceUnavailable }
            var selected = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &selected,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioCaptureError.coreAudio(status) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let ownedFormat = AVAudioFormat(streamDescription: format.streamDescription) else {
            throw AudioCaptureError.deviceUnavailable
        }
        let converter = try PCMConverter(inputFormat: ownedFormat)
        let processor = AudioTapProcessor(converter: converter, onSamples: onSamples, onInterruption: onInterruption)
        self.processor = processor
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: processor.tap)
        tapInstalled = true
        observers.observe(center: .default, name: .AVAudioEngineConfigurationChange, objectID: ObjectIdentifier(engine)) {
            onInterruption(.configurationChanged)
        }
        let workspaceCenter = await MainActor.run { NSWorkspace.shared.notificationCenter }
        observers.observe(center: workspaceCenter, name: NSWorkspace.didWakeNotification) {
            onInterruption(.systemWoke)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        observers.removeAll()
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        processor?.close()
        processor = nil
        engine = nil
    }

    private static func resolveDevice(uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        let status = withUnsafeMutablePointer(to: &value) { input in
            withUnsafeMutablePointer(to: &device) { output in
                var translation = AudioValueTranslation(mInputData: input,
                                                        mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                                                        mOutputData: output,
                                                        mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                  0, nil, &size, &translation)
            }
        }
        guard status == noErr else { throw AudioCaptureError.coreAudio(status) }
        guard device != kAudioObjectUnknown else { throw AudioCaptureError.deviceUnavailable }
        return device
    }
}
