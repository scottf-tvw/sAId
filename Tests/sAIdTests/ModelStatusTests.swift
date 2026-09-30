import Foundation
import Testing
@testable import sAId

struct ModelStatusTests {
    @Test func progressIsNotReadinessAndStaleCallbacksCannotEnableReplacement() {
        var model = ModelStatus()
        let first = model.begin()
        model.update(progress: 1, detail: "Loading native model", generation: first)
        #expect(model.readiness == .loading)
        let second = model.begin()
        model.finish(.ready, generation: first)
        model.update(progress: 1, detail: "stale", generation: first)
        #expect(model.readiness == .loading)
        #expect(model.progress == 0)
        model.finish(.failed("Retry needed"), generation: second)
        model.update(progress: 1, detail: "late progress", generation: second)
        #expect(model.detail == "Retry needed")
        let third = model.begin()
        model.finish(.ready, generation: third)
        #expect(model.readiness == .ready)
    }
    @Test func defaultsResolveFromRealApplicationResourceLayout() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        defer { try? FileManager.default.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents"), resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "org.tvw.said.resource-test", "CFBundlePackageType": "APPL", "CFBundleName": "Resource test"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let corrections = [Correction(from: "test", to: "Bundled")]
        try JSONEncoder().encode(corrections).write(to: resources.appendingPathComponent("default-corrections.json"))
        try JSONEncoder().encode(["custom bundled filler"]).write(to: resources.appendingPathComponent("default-fillers.json"))
        let bundle = try #require(Bundle(url: app))
        let defaults = BundledDefaults.load(bundle: bundle)
        #expect(defaults.corrections == corrections)
        #expect(defaults.fillers == ["custom bundled filler"])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        #expect(try JSONDecoder().decode([Correction].self, from: Data(contentsOf: source.appendingPathComponent("default-corrections.json"))) == Correction.defaults)
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: source.appendingPathComponent("default-fillers.json"))) == FillerRemoval.defaults)
    }
}
