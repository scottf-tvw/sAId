import XCTest
@testable import sAId
final class HUDViewModelTests: XCTestCase {
    func testPresentationShowsTrailingWordsAndIndependentErrors() {
        var state = DictationState(readiness: .ready, phase: .listening(session: .init(rawValue: 1), preview: "one two three four five six seven eight nine ten eleven twelve thirteen", seconds: 1))
        XCTAssertEqual(HUDPresentation(state).text, "two three four five six seven eight nine ten eleven twelve thirteen")
        XCTAssertEqual(HUDPresentation(state).activity, .listening)
        state.message = .error("Secure input field")
        XCTAssertEqual(HUDPresentation(state).notice, "Secure input field")
        XCTAssertTrue(HUDPresentation(state).visible)
    }
    func testPresentationMapsLifecycleWithoutCreatingWindow() {
        let phases: [(DictationPhase, HUDActivity, Bool)] = [(.loadingModels, .loading, true), (.idle, .none, false), (.finalizing(session: .init(rawValue: 1), preview: "words"), .finalizing, true), (.inserting(session: .init(rawValue: 1), final: "words"), .finalizing, true), (.shown(final: "done"), .completed, true), (.nothingHeard, .none, true), (.error("failed"), .error, true)]
        for (phase, activity, visible) in phases {
            let model = HUDPresentation(DictationState(phase: phase))
            XCTAssertEqual(model.activity, activity); XCTAssertEqual(model.visible, visible)
        }
    }
}
