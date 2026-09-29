// REFERENCE ONLY — not compiled.
// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
// Extracted from TVWIT/hAIvd-Assist commit 5b0f9a7, sidecar/Sources/HaiveSpeechSidecar/main.swift,
// region "Audio capture" (lines 1993-2296). Adapt into sAId modules; keep this notice on derived files.

// MARK: - Audio capture
//
// AVAudioEngine tap on the input node, downmix to mono / 16 kHz /
// Float32 if needed, append to a buffer while recording.
//
// Deliberately NOT @MainActor. AVAudioEngine's installTap delivers
// callbacks on an audio worker thread. Under Swift 6 strict
// concurrency, calling a @MainActor method from that thread triggers
// dispatch_assert_queue_fail (SIGTRAP) and kills the process. We
// instead guard mutable state with NSLock and let the tap callback
// run wherever AVFoundation calls it.

final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var manuallyMixInputToMono = false
    private let lock = NSLock()
    private var samples: [Float] = []
    private var _isRunning = false
    private var latestLevel: Float = 0
    private var latestLevelSequence: UInt64 = 0
    private var recordingGeneration: UInt64 = 0
    private var configurationObserver: NSObjectProtocol?

    var onConfigurationChange: (@Sendable () -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    func startEngine(inputDevicePreference: String = "") throws {
        let input = engine.inputNode
        applyInputDevicePreference(inputDevicePreference, to: input)
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: 1,
            interleaved: false
        ) else { throw NSError(domain: "Parakey", code: -1) }

        let sourceFormat = converterSourceFormat(for: inputFormat)
        converterInputFormat = sourceFormat
        manuallyMixInputToMono = inputFormat.channelCount > 1 && sourceFormat.channelCount == 1
        converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        let mixLabel = manuallyMixInputToMono ? " via manual mono mix" : ""
        log("AudioCapture: input \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch\(mixLabel) → \(targetFormat.sampleRate) Hz mono")

        // Capture targetFormat by value into the closure. self is
        // weak so the engine doesn't keep AudioCapture alive past
        // its owner. The closure runs on AVFoundation's audio
        // thread — handleTap is non-isolated and uses NSLock for
        // any shared-state access.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, target: targetFormat)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
            throw error
        }
        installConfigurationObserver()
        log("AudioCapture: engine started")
    }

    func stopEngine() {
        removeConfigurationObserver()

        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        converterInputFormat = nil
        manuallyMixInputToMono = false
    }

    private func installConfigurationObserver() {
        removeConfigurationObserver()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    func beginRecording() {
        lock.lock(); defer { lock.unlock() }
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        latestLevelSequence &+= 1
        _isRunning = true
    }

    /// Stops recording and returns the captured samples.
    func endRecording() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        return captured
    }

    func latestRecordingLevelSnapshot() -> (level: Float, sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return _isRunning ? (latestLevel, latestLevelSequence) : (0, latestLevelSequence)
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Snapshot the running flag under lock; bail fast if we're
        // not recording so we don't pay conversion cost for nothing.
        lock.lock()
        let running = _isRunning
        let generation = recordingGeneration
        lock.unlock()
        guard running, let converter else { return }

        let converterInput = preparedConverterInputBuffer(from: buffer) ?? buffer
        let ratio = target.sampleRate / converterInput.format.sampleRate
        let outCap = AVAudioFrameCount(Double(converterInput.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        // .noDataNow vs .endOfStream: this is reusing the same
        // AVAudioConverter across every tap callback (~50 Hz). If we
        // signal .endOfStream after the buffer, the converter goes
        // into a terminal state and produces 0 samples on every
        // subsequent call — exactly the "first capture was 0.10s,
        // every press after that was 0.00s" bug we saw before this
        // fix. .noDataNow means "I'm out of input *for this call*,
        // but the stream continues" and leaves the converter usable.
        let inputProvider = AudioConverterInputProvider(buffer: converterInput)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        var arr: [Float] = []
        arr.reserveCapacity(frameCount)
        var sumSquares: Double = 0
        var finiteSampleCount = 0
        for sample in UnsafeBufferPointer(start: ch, count: frameCount) {
            arr.append(sample)
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
            finiteSampleCount += 1
        }
        let level = normalizedAudioLevel(sumSquares: sumSquares,
                                         sampleCount: finiteSampleCount)

        // Re-check running under lock — endRecording() might have
        // fired during conversion, then a rapid next recording may
        // already have started. The generation token keeps straggler
        // frames out of the next clip.
        lock.lock()
        if _isRunning && recordingGeneration == generation {
            samples.append(contentsOf: arr)
            latestLevel = level
            latestLevelSequence &+= 1
        }
        lock.unlock()
    }

    private func converterSourceFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        guard inputFormat.channelCount > 1,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            return inputFormat
        }
        return monoFormat
    }

    private func preparedConverterInputBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard manuallyMixInputToMono else { return buffer }
        guard let monoFormat = converterInputFormat,
              let channels = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 1, frameCount > 0 else { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let mono = out.floatChannelData?[0] else {
            return nil
        }

        var channelRMS = Array(repeating: 0.0, count: channelCount)
        for channelIndex in 0..<channelCount {
            var sumSquares = 0.0
            let source = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = source[frameIndex]
                guard sample.isFinite else { continue }
                let clamped = max(-1, min(1, sample))
                sumSquares += Double(clamped * clamped)
            }
            channelRMS[channelIndex] = sqrt(sumSquares / Double(frameCount))
        }

        let peak = channelRMS.max() ?? 0
        let activeChannels = channelRMS.enumerated()
            .filter { pair in peak > 0 && pair.element >= peak * 0.25 }
            .map { $0.offset }
        let selectedChannels = activeChannels.isEmpty ? [0] : activeChannels
        let scale = Float(1.0 / Double(selectedChannels.count))

        for frameIndex in 0..<frameCount {
            var mixed: Float = 0
            for channelIndex in selectedChannels {
                mixed += channels[channelIndex][frameIndex] * scale
            }
            mono[frameIndex] = mixed
        }
        out.frameLength = AVAudioFrameCount(frameCount)
        return out
    }

    private func applyInputDevicePreference(_ preference: String, to input: AVAudioInputNode) {
        let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isDefaultAggregateAudioInputPreference(trimmed) else { return }

        guard let device = audioInputDevice(matching: trimmed) else {
            log("AudioCapture: saved input device unavailable, using system default")
            return
        }
        guard let unit = input.audioUnit else {
            log("AudioCapture: input audio unit unavailable, using system default")
            return
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            log("AudioCapture: input device switch failed (\(status)), using system default")
            return
        }
        log("AudioCapture: selected input \(device.name)")
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if didProvideBuffer {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}

