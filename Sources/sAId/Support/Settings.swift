import Combine
import CoreGraphics
import Foundation

enum HotkeyChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case rightOption, rightControl, rightCommand, f13, f14, f15
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rightOption: "Right Option ⌥"
        case .rightControl: "Right Control ⌃"
        case .rightCommand: "Right Command ⌘"
        case .f13: "F13"
        case .f14: "F14"
        case .f15: "F15"
        }
    }
    var hotkey: Hotkey {
        switch self {
        case .rightOption: .rightOption
        case .rightControl: Hotkey(keycode: 62, modifierFlag: .maskControl)
        case .rightCommand: Hotkey(keycode: 54, modifierFlag: .maskCommand)
        case .f13: Hotkey(keycode: 105)
        case .f14: Hotkey(keycode: 107)
        case .f15: Hotkey(keycode: 113)
        }
    }
}
struct AppPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var hotkey: HotkeyChoice = .rightOption
    var inputDeviceUID = ""
    var removeFillers = true
    var customFillers: [String] = []
    var trailingSpace = false
    var insertionStrategy: TextInsertionStrategy = .clipboardPaste
    func validate() throws {
        guard customFillers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SettingsError.invalid("Filler phrases cannot be blank.")
        }
    }
}
enum SettingsError: LocalizedError {
    case invalid(String), damaged
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .damaged: "Settings could not be read. Recover saved preferences before making changes."
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var preferences = AppPreferences()
    @Published private(set) var corrections: [Correction]
    @Published private(set) var errorMessage: String?
    @Published private(set) var correctionsError: String?
    private let directory: URL
    private let defaultFillers: [String]
    private var damagedPreferences = false
    private var damagedCorrections = false
    var onChange: (() -> Void)?
    init(directory: URL = AppFiles.directory, defaults: BundledDefaults = .load()) {
        self.directory = directory; corrections = defaults.corrections; defaultFillers = defaults.fillers
        do {
            let loaded = try AppFiles.load(AppPreferences.self, from: directory.appendingPathComponent("settings.json"), fallback: AppPreferences())
            try loaded.validate(); preferences = loaded
        } catch { damagedPreferences = true; errorMessage = "Saved preferences are unreadable and have been preserved. Recover preferences to save changes." }
        do {
            let loaded = try AppFiles.load([Correction].self, from: directory.appendingPathComponent("corrections.json"), fallback: defaults.corrections)
            try Self.validateCorrections(loaded); corrections = loaded
        } catch { damagedCorrections = true; correctionsError = "Saved corrections are unreadable and preserved. Saving or importing a valid list archives the original file." }
    }
    var postProcess: PostProcess {
        PostProcess(corrections: corrections, fillers: preferences.removeFillers ? defaultFillers + preferences.customFillers : [], trailingSpace: preferences.trailingSpace)
    }
    func update(_ next: AppPreferences) throws {
        guard !damagedPreferences else { throw SettingsError.damaged }
        try next.validate()
        try AppFiles.save(next, to: directory.appendingPathComponent("settings.json"))
        preferences = next; errorMessage = nil; onChange?()
    }
    func recoverPreferences() throws {
        let url = directory.appendingPathComponent("settings.json")
        try AppFiles.archiveDamaged(url)
        try AppFiles.save(AppPreferences(), to: url)
        damagedPreferences = false; preferences = AppPreferences(); errorMessage = nil; onChange?()
    }
    func replaceCorrections(_ next: [Correction]) throws {
        try Self.validateCorrections(next)
        let url = directory.appendingPathComponent("corrections.json")
        if damagedCorrections { try AppFiles.archiveDamaged(url) }
        try AppFiles.save(next, to: url)
        corrections = next; damagedCorrections = false; correctionsError = nil; onChange?()
    }
    func importCorrections(_ data: Data) throws { try replaceCorrections(JSONDecoder().decode([Correction].self, from: data)) }
    func exportCorrections() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(corrections)
    }
    static func validateCorrections(_ values: [Correction]) throws {
        var sources = Set<String>()
        for value in values {
            let source = value.from.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            guard !source.isEmpty else { throw SettingsError.invalid("Correction source cannot be blank.") }
            guard sources.insert(source).inserted else { throw SettingsError.invalid("Each correction source must be unique.") }
        }
    }
}

struct BundledDefaults {
    let corrections: [Correction]
    let fillers: [String]
    /// Xcode copies these files to Contents/Resources (no SPM resource bundle).
    static func load(bundle: Bundle = .main) -> Self {
        guard let correctionsURL = bundle.url(forResource: "default-corrections", withExtension: "json"),
              let fillersURL = bundle.url(forResource: "default-fillers", withExtension: "json"),
              let corrections = try? JSONDecoder().decode([Correction].self, from: Data(contentsOf: correctionsURL)),
              let fillers = try? JSONDecoder().decode([String].self, from: Data(contentsOf: fillersURL)) else {
            return Self(corrections: Correction.defaults, fillers: FillerRemoval.defaults)
        }
        return Self(corrections: corrections, fillers: fillers)
    }
}
