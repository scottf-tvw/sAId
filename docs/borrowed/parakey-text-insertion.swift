// REFERENCE ONLY — not compiled.
// Borrowed from Parakey <https://github.com/rcourtman/parakey>, MIT License,
// Copyright (c) 2026 Richard Courtman (see docs/borrowed/PARAKEY-LICENSE).
// Extracted from TVWIT/hAIvd-Assist commit 5b0f9a7, sidecar/Sources/HaiveSpeechSidecar/main.swift,
// region "Text insertion" (lines 2472-2653). Adapt into sAId modules; keep this notice on derived files.

// MARK: - Text insertion
//
// Default path: write to general pasteboard, post Cmd+V. If that setup
// fails, fall back to direct Unicode events so a pasteboard problem
// does not automatically lose the transcript. We deliberately don't
// preserve and restore the user's previous clipboard contents — trying
// to round-trip it racily fights with paste-managers and other
// clipboard observers, and most users find a clipboard that silently
// reverts itself more surprising than one that ends up holding whatever
// they last dictated.

func pastedText(from correctedTranscript: String, suffix: PasteSuffix) -> String {
    switch suffix {
    case .appendSpace:
        return correctedTranscript + " "
    case .none:
        return correctedTranscript
    case .appendNewline:
        return correctedTranscript + "\n"
    }
}

func speechModelStartupStatusTitle(_ progress: DownloadUtils.DownloadProgress) -> String {
    switch progress.phase {
    case .listing:
        return "Checking speech model files…"
    case .downloading(let completedFiles, let totalFiles):
        guard totalFiles > 0 else { return "Loading cached speech model…" }
        let downloadFraction = min(max(progress.fractionCompleted / 0.5, 0), 1)
        let percent = min(100, max(0, Int((downloadFraction * 20).rounded()) * 5))
        return "Downloading speech model… \(percent)% (\(completedFiles)/\(totalFiles))"
    case .compiling:
        return "Preparing speech model…"
    }
}

enum TextInsertionStrategy: String {
    case clipboardPaste
    case directUnicode

    var displayName: String {
        switch self {
        case .clipboardPaste: return "Clipboard paste"
        case .directUnicode: return "Direct Unicode typing"
        }
    }
}

func textInsertionStrategyChain(primary: TextInsertionStrategy) -> [TextInsertionStrategy] {
    switch primary {
    case .clipboardPaste:
        return [.clipboardPaste, .directUnicode]
    case .directUnicode:
        return [.directUnicode]
    }
}

func textInsertionStrategyDescription(primary: TextInsertionStrategy) -> String {
    let strategies = textInsertionStrategyChain(primary: primary).map(\.displayName)
    guard let first = strategies.first else { return "Unavailable" }
    guard strategies.count > 1 else { return first }
    return "\(first) with \(strategies.dropFirst().joined(separator: ", ")) fallback"
}

func unicodeInsertionChunks(for text: String, maxUTF16UnitsPerEvent maxUnits: Int) -> [[UInt16]] {
    guard maxUnits > 0 else { return [] }
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []

    for character in text {
        let units = Array(String(character).utf16)
        if units.count > maxUnits {
            if !current.isEmpty {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            chunks.append(units)
            continue
        }
        if !current.isEmpty, current.count + units.count > maxUnits {
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
        }
        current.append(contentsOf: units)
    }

    if !current.isEmpty {
        chunks.append(current)
    }
    return chunks
}

@MainActor
enum TextInserter {
    nonisolated static let defaultStrategy = TextInsertionStrategy.clipboardPaste

    nonisolated static var defaultStrategyDescription: String {
        textInsertionStrategyDescription(primary: defaultStrategy)
    }

    @discardableResult
    static func insert(_ text: String, strategy: TextInsertionStrategy = defaultStrategy) -> Bool {
        for candidate in textInsertionStrategyChain(primary: strategy) {
            if insert(text, using: candidate) {
                if candidate != strategy {
                    log("text insertion fallback succeeded: \(candidate.displayName)")
                }
                return true
            }
            log("text insertion attempt failed: \(candidate.displayName)")
        }
        return false
    }

    private static func insert(_ text: String, using strategy: TextInsertionStrategy) -> Bool {
        switch strategy {
        case .clipboardPaste:
            return ClipboardPasteInserter.insert(text)
        case .directUnicode:
            return DirectUnicodeInserter.insert(text)
        }
    }
}

@MainActor
private enum ClipboardPasteInserter {
    private static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'

    static func write(_ text: String, to pb: NSPasteboard) -> Bool {
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    static func insert(_ text: String) -> Bool {
        guard write(text, to: .general) else {
            log("pasteboard write failed")
            return false
        }

        let src = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKeyV, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKeyV, keyDown: false)
        else {
            log("paste event creation failed")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
private enum DirectUnicodeInserter {
    private static let maxUTF16UnitsPerEvent = 20

    static func insert(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        var didPostAll = true

        for chunk in unicodeInsertionChunks(for: text, maxUTF16UnitsPerEvent: maxUTF16UnitsPerEvent) {
            didPostAll = post(chunk, source: source) && didPostAll
        }
        return didPostAll
    }

    private static func post(_ units: [UInt16], source: CGEventSource?) -> Bool {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            return false
        }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        event.post(tap: .cghidEventTap)
        return true
    }
}

