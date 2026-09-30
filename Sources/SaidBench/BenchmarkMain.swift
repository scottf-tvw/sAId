import Darwin
import Foundation
import SaidEngine

@main
struct BenchmarkMain {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("said-bench: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run(_ arguments: [String]) async throws {
        if arguments == ["--help"] {
            print("Usage: said-bench [--preview] [--model-root PATH] WAV_DIRECTORY REFERENCES.json\nOffline only. Reports prerecorded compute time, not live latency.")
            return
        }
        var preview = false, modelRoot = defaultModelRoot, positional: [String] = [], index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--preview": preview = true
            case "--model-root":
                index += 1
                guard index < arguments.count else { throw BenchmarkError("--model-root requires a path") }
                modelRoot = URL(fileURLWithPath: arguments[index], isDirectory: true)
            default:
                guard !argument.hasPrefix("--") else { throw BenchmarkError("Unknown option: \(argument)") }
                positional.append(argument)
            }
            index += 1
        }
        guard positional.count == 2 else { throw BenchmarkError("Usage: said-bench [--preview] [--model-root PATH] WAV_DIRECTORY REFERENCES.json") }
        // Validate every input before model loading, and load exactly once for the entire corpus.
        let corpus = try BenchmarkCorpus(directory: URL(fileURLWithPath: positional[0], isDirectory: true),
                                         references: URL(fileURLWithPath: positional[1]))
        let engine = MoonshineEngine(modelRoot: modelRoot)
        let clock = ContinuousClock(), loading = clock.now
        try await engine.load(downloadIfMissing: false)
        print("Moonshine 0.1.5 English mediumStreaming; one resident model; offline")
        print("load_and_verify_seconds=\(seconds(loading.duration(to: clock.now)))")
        print("WER: lowercase alphanumeric tokens; no number expansion; corpus sums edits/reference words")
        print("Empty reference: empty hypothesis WER=0; nonempty WER=undefined (insertions still count in corpus)")
        print("Timing: prerecorded fast-feed compute seconds, NOT live microphone or release-to-paste latency")
        var finalTotal = WordError(edits: 0, references: 0), previewTotal = finalTotal
        var finalSeconds = 0.0, previewSeconds = 0.0, audioSeconds = 0.0
        for entry in corpus.entries {
            audioSeconds += entry.audio.duration
            if preview {
                let begin = clock.now, stream = try await engine.start()
                do {
                    for offset in stride(from: 0, to: entry.audio.samples.count, by: 4800) {
                        try await engine.feed(Array(entry.audio.samples[offset..<min(offset + 4800, entry.audio.samples.count)]))
                    }
                    await engine.stop()
                    var text = ""
                    for try await line in stream { text = line.text }
                    let elapsed = seconds(begin.duration(to: clock.now))
                    let result = WordError.measure(reference: entry.reference, hypothesis: text)
                    previewTotal = previewTotal + result; previewSeconds += elapsed
                    report(entry.filename, path: "preview", result: result, elapsed: elapsed, text: text)
                } catch { await engine.stop(); throw error }
            }
            let begin = clock.now, text = try await engine.transcribe(entry.audio.samples)
            let elapsed = seconds(begin.duration(to: clock.now))
            let result = WordError.measure(reference: entry.reference, hypothesis: text)
            finalTotal = finalTotal + result; finalSeconds += elapsed
            report(entry.filename, path: "final", result: result, elapsed: elapsed, text: text)
        }
        print("audio_seconds=\(audioSeconds) files=\(corpus.entries.count)")
        if preview { report("CORPUS", path: "preview", result: previewTotal, elapsed: previewSeconds, text: nil) }
        report("CORPUS", path: "final", result: finalTotal, elapsed: finalSeconds, text: nil)
        try await engine.releaseForExplicitReset()
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func report(_ name: String, path: String, result: WordError, elapsed: Double, text: String?) {
        print("\(name) path=\(path) edits=\(result.edits) reference_words=\(result.references) WER=\(result.rate.map { String(format: "%.6f", $0) } ?? "undefined") compute_seconds=\(String(format: "%.6f", elapsed))")
        if let text { print("  hypothesis: \(text)") }
    }
}
