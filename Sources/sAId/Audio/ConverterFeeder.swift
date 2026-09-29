import AVFoundation
import Synchronization

/// Each converter request consumes an owned buffer once. An empty request is temporary,
/// never endOfStream: terminating the converter makes later presses capture silence.
final class ConverterFeeder: Sendable {
    private let pending: Mutex<AVAudioPCMBuffer?>

    init(buffer: sending AVAudioPCMBuffer) { pending = Mutex(buffer) }

    private func take() -> sending AVAudioPCMBuffer? {
        pending.withLock { value in
            let buffer = value
            value = nil
            return buffer
        }
    }

    var inputBlock: AVAudioConverterInputBlock {
        { [self] _, status in
            guard let buffer = take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return buffer
        }
    }
}

/// Conversion runs synchronously on the tap, serialized by checked mutex isolation.
/// Only copied/owned input buffers enter this object; AVFoundation storage never escapes.
final class PCMConverter: Sendable {
    private struct State {
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
        var inputFrames: Int64 = 0
        var outputFrames: Int64 = 0
        var drained = false
    }
    private let state: Mutex<State>

    convenience init(sampleRate: Double, channels: AVAudioChannelCount) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw AudioCaptureError.invalidFormat
        }
        try self.init(inputFormat: format)
    }

    init(inputFormat: sending AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.invalidFormat
        }
        // AVAudioConverter defaults to channel remapping, which silently selects only
        // the first stereo channel. Mix all input channels into the mono output.
        converter.downmix = true
        state = Mutex(State(converter: converter, outputFormat: outputFormat))
    }

    func convert(buffer: sending AVAudioPCMBuffer) throws -> [Float] {
        let frames = buffer.frameLength
        let capacity = AVAudioFrameCount(ceil(Double(frames) * 16_000 / buffer.format.sampleRate)) + 64
        let feeder = ConverterFeeder(buffer: buffer)
        return try state.withLock { state in
            guard !state.drained else { throw AudioCaptureError.conversionFailed }
            state.inputFrames += Int64(frames)
            let output = try Self.render(feeder: feeder, capacity: capacity, state: state)
            state.outputFrames += Int64(output.count)
            return output
        }
    }

    private static func render(feeder: ConverterFeeder, capacity: AVAudioFrameCount, state: State) throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: state.outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.invalidFormat
        }
        var error: NSError?
        let status = state.converter.convert(to: output, error: &error, withInputFrom: feeder.inputBlock)
        if let error { throw error }
        guard status != .error else { throw AudioCaptureError.conversionFailed }
        guard let samples = output.floatChannelData?[0] else { throw AudioCaptureError.invalidFormat }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }

    /// Feed trailing silence once and retain only the output belonging to accepted input.
    /// The live converter may retain part of its current resampling block even when its
    /// primeInfo reports zero. Frame accounting avoids truncating that final block, while
    /// the feeder still returns noDataNow and never puts the converter into a terminal state.
    func drain() throws -> [Float] {
        try state.withLock { state in
            guard !state.drained else { return [] }
            state.drained = true
            let format = state.converter.inputFormat
            let expected = Int64(floor(Double(state.inputFrames) * 16_000 / format.sampleRate))
            let remaining = Int(max(0, expected - state.outputFrames))
            guard remaining > 0 else { return [] }
            // Bound the work to one small trailing buffer. The extra 100 ms fills the
            // converter's internal block; it is trimmed away rather than emitted as audio.
            let frames = AVAudioFrameCount(ceil(Double(remaining) * format.sampleRate / 16_000 + format.sampleRate / 10))
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let planes = Array(repeating: Data(count: Int(frames) * bytesPerFrame),
                               count: format.isInterleaved ? 1 : Int(format.channelCount))
            let silence = try Self.makeOwnedBuffer(sampleRate: format.sampleRate, channels: format.channelCount,
                                                  commonFormat: format.commonFormat, interleaved: format.isInterleaved,
                                                  frames: frames, planes: planes)
            let feeder = ConverterFeeder(buffer: silence)
            let capacity = AVAudioFrameCount(ceil(Double(frames) * 16_000 / format.sampleRate)) + 64
            let output = try Self.render(feeder: feeder, capacity: capacity, state: state)
            guard output.count >= remaining else { throw AudioCaptureError.conversionFailed }
            state.outputFrames += Int64(remaining)
            return Array(output.prefix(remaining))
        }
    }

    /// A tap owns its buffer only for the callback. Copy the audio data before transferring it.
    static func copy(_ source: AVAudioPCMBuffer) throws -> sending AVAudioPCMBuffer {
        let format = source.format
        let planes = try UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList)).map {
            guard let data = $0.mData else { throw AudioCaptureError.invalidFormat }
            return Data(bytes: data, count: Int($0.mDataByteSize))
        }
        return try makeOwnedBuffer(sampleRate: format.sampleRate, channels: format.channelCount,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved,
                                   frames: source.frameLength, planes: planes)
    }

    // A Sendable value snapshot separates callback-borrowed storage from newly owned storage.
    // This deliberately avoids telling Swift to trust AVFoundation buffers across threads.
    private static func makeOwnedBuffer(sampleRate: Double, channels: AVAudioChannelCount,
                                        commonFormat: AVAudioCommonFormat, interleaved: Bool,
                                        frames: AVAudioFrameCount, planes: [Data]) throws -> sending AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate,
                                         channels: channels, interleaved: interleaved),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioCaptureError.invalidFormat
        }
        buffer.frameLength = frames
        let outputs = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard outputs.count == planes.count else { throw AudioCaptureError.invalidFormat }
        for (data, output) in zip(planes, outputs) {
            guard let destination = output.mData, data.count <= Int(output.mDataByteSize) else {
                throw AudioCaptureError.invalidFormat
            }
            data.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: data.count))
        }
        return buffer
    }
}
