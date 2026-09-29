import AVFoundation
import XCTest
@testable import sAId

@MainActor
final class ConverterFeederTests: XCTestCase {
    func testInputIsConsumedOnceAcrossPresses() throws {
        for _ in 0..<2 {
            let buffer = try syntheticBuffer(channels: 1, level: 0.1)
            buffer.frameLength = 480
            let feeder = ConverterFeeder(buffer: buffer)
            var status = AVAudioConverterInputStatus.endOfStream
            XCTAssertNotNil(feeder.inputBlock(480, &status))
            XCTAssertEqual(status, .haveData)
            XCTAssertNil(feeder.inputBlock(480, &status))
            XCTAssertEqual(status, .noDataNow)
        }
    }

    func testConvertsMonoAndStereoToOrderedFinite16kSamples() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            let converter = try PCMConverter(sampleRate: 48_000, channels: channels)
            var result: [Float] = []
            for level: Float in [0.2, 0.6, -0.4] {
                let buffer = try syntheticBuffer(channels: channels, level: level, stereoSpread: channels == 2 ? 0.1 : 0)
                result.append(contentsOf: try converter.convert(buffer: buffer))
            }
            XCTAssertGreaterThan(result.count, 4_500)
            XCTAssertLessThanOrEqual(result.count, 4_800)
            XCTAssertTrue(result.allSatisfy(\.isFinite))
            guard result.count > 4_000 else { continue }
            XCTAssertEqual(result[800], 0.2, accuracy: 0.01)
            XCTAssertEqual(result[2_400], 0.6, accuracy: 0.01)
            XCTAssertEqual(result[4_000], -0.4, accuracy: 0.01)
        }
    }

    func testCopiedTapBufferIsIndependentOfBorrowedStorage() throws {
        let original = try syntheticBuffer(channels: 2, level: 0.25)
        let copy = try PCMConverter.copy(original)
        original.floatChannelData?[0][0] = -0.75
        XCTAssertEqual(copy.floatChannelData?[0][0], 0.25)
        XCTAssertEqual(copy.frameLength, original.frameLength)
        XCTAssertEqual(copy.format.channelCount, 2)
    }


    func testDrainYieldsTheResamplerTailExactlyOnce() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            let converter = try PCMConverter(sampleRate: 48_000, channels: channels)
            let first = try converter.convert(buffer: syntheticBuffer(channels: channels, level: 0.25))
            let tail = try converter.drain()
            XCTAssertEqual(first.count + tail.count, 1_600)
            XCTAssertTrue((first + tail).allSatisfy(\.isFinite))
            XCTAssertTrue(try converter.drain().isEmpty)
        }
    }

    func testTapClosureRunsOffMainAndShutdownRejectsLateBuffers() async throws {
        let sink = SampleSink()
        let processor = AudioTapProcessor(converter: try PCMConverter(sampleRate: 48_000, channels: 2),
                                          onSamples: { sink.record($0) },
                                          onInterruption: { _ in sink.record([]) })
        try await Task.detached {
            let buffer = try syntheticBuffer(channels: 2, level: 0.25)
            processor.tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }.value
        processor.close()
        try await Task.detached {
            let buffer = try syntheticBuffer(channels: 2, level: 0.75)
            processor.tap(buffer, AVAudioTime(sampleTime: 4_800, atRate: 48_000))
        }.value
        let chunks = sink.chunks()
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.flatMap { $0 }.count, 1_600)
        XCTAssertEqual(chunks[0][800], 0.25, accuracy: 0.01)
    }

}

private func syntheticBuffer(channels: AVAudioChannelCount, level: Float, stereoSpread: Float = 0) throws -> sending AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
    buffer.frameLength = 4_800
    for channel in 0..<Int(channels) {
        let data = try XCTUnwrap(buffer.floatChannelData?[channel])
        for frame in 0..<4_800 { data[frame] = level + (channel == 0 ? stereoSpread : -stereoSpread) }
    }
    return buffer
}

import Synchronization
private final class SampleSink: Sendable {
    private let samples = Mutex<[[Float]]>([])
    func record(_ chunk: [Float]) { samples.withLock { $0.append(chunk) } }
    func chunks() -> [[Float]] { samples.withLock { $0 } }
}
