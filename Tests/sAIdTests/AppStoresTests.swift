import Foundation
import Testing
@testable import sAId

@MainActor
struct AppStoresTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func historyPersistsNewestFiftyAndClear() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), store = HistoryStore(fileURL: root.appendingPathComponent("history.json"))
        for index in 0..<55 {
            store.record(DictationHistoryEntry(text: "text \(index)", timestamp: Date(timeIntervalSince1970: Double(index)), targetAppID: "target", source: .previewAfterFinalFailure, failure: "failure"))
        }
        #expect(store.entries.count == 50)
        #expect(store.entries.first?.text == "text 54")
        #expect(HistoryStore(fileURL: url).entries == store.entries)
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(HistoryStore(fileURL: url).entries.isEmpty)
    }
    @Test func corruptHistoryIsNeverOverwrittenByRecording() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), damaged = Data("broken".utf8)
        try damaged.write(to: url)
        let store = HistoryStore(fileURL: url)
        #expect(store.errorMessage != nil)
        store.record(DictationHistoryEntry(text: "retained in memory", timestamp: Date(), targetAppID: nil, source: .final, failure: nil))
        #expect(try Data(contentsOf: url) == damaged)
        #expect(store.entries.count == 1)
        store.clear()
        #expect(store.errorMessage == nil)
        #expect(HistoryStore(fileURL: url).entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.contains("damaged") }))
    }
    @Test func permissionsAndReadinessNeverOverrideEachOther() {
        for bits in 0..<8 {
            let grants = PermissionStatus(microphone: bits & 1 != 0, inputMonitoring: bits & 2 != 0, accessibility: bits & 4 != 0)
            #expect(AppReadiness(enabled: true, permissions: grants, model: .ready).canDictate == (bits == 7))
            #expect(!AppReadiness(enabled: false, permissions: grants, model: .ready).canDictate)
            #expect(!AppReadiness(enabled: true, permissions: grants, model: .loading).canDictate)
            #expect(!AppReadiness(enabled: true, permissions: grants, model: .failed("failure")).canDictate)
        }
    }
    @Test func settingsRoundTripAndValidation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(directory: root)
        var next = settings.preferences
        next.hotkey = .rightControl; next.customFillers = ["basically"]; next.trailingSpace = true
        next.insertionStrategy = .directUnicode; next.inputDeviceUID = "device"
        try settings.update(next)
        let reloaded = SettingsStore(directory: root)
        #expect(reloaded.preferences == next)
        #expect(reloaded.postProcess.apply("basically hello") == "Hello ")
        next.customFillers = ["  "]
        #expect(throws: (any Error).self) { try settings.update(next) }
        #expect(settings.preferences == reloaded.preferences)
    }
    @Test func correctionsEmptyPersistsAndInvalidImportDoesNotReplace() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(directory: root)
        try settings.replaceCorrections([])
        #expect(SettingsStore(directory: root).corrections.isEmpty)
        let before = try Data(contentsOf: root.appendingPathComponent("corrections.json"))
        #expect(throws: (any Error).self) { try settings.importCorrections(Data("[{\"from\":\" \" ,\"to\":\"x\"}]".utf8)) }
        #expect(settings.corrections.isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("corrections.json")) == before)
        try settings.importCorrections(Data("[{\"from\":\"word\",\"to\":\"Brand\"}]".utf8))
        #expect(try JSONDecoder().decode([Correction].self, from: settings.exportCorrections()) == settings.corrections)
    }
    @Test func corruptSettingsPreserveSourceUntilExplicitRecovery() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json"), damaged = Data("damaged".utf8)
        try damaged.write(to: url)
        let settings = SettingsStore(directory: root)
        #expect(settings.errorMessage != nil)
        #expect(throws: (any Error).self) { try settings.update(AppPreferences()) }
        #expect(try Data(contentsOf: url) == damaged)
        try settings.recoverPreferences()
        #expect(SettingsStore(directory: root).errorMessage == nil)
    }
}
