import CoreGraphics
import XCTest
@testable import sAId

@MainActor
final class HotkeyDeciderTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate.rawValue
    private func event(_ type: CGEventType, _ code: UInt16, flags: UInt64 = 0, repeatKey: Bool = false) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(typeRawValue: type.rawValue, keycode: code,
                            flagsRawValue: flags, isAutoRepeat: repeatKey)
    }

    func testOnlyConfiguredPhysicalOptionStartsAndStopsHold() {
        var decider = HotkeyDecider()
        XCTAssertEqual(decider.transition(event(.flagsChanged, 58, flags: option)).action, .none)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 61, flags: option)).action, .pressed)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 58, flags: option)).action, .none)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 61)).action, .released)
    }

    func testRightOptionReleaseWhileLeftStillHeldReleases() {
        var decider = HotkeyDecider()
        XCTAssertEqual(decider.transition(event(.flagsChanged, 61, flags: option)).action, .pressed)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 58, flags: option)).action, .none)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 61, flags: option)).action, .released)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 58)).action, .none)
    }

    func testOrdinaryKeyRepeatAndDuplicateDownDoNotPressAgain() {
        var decider = HotkeyDecider(hotkey: Hotkey(keycode: 49))
        XCTAssertEqual(decider.transition(event(.keyDown, 49)).action, .pressed)
        XCTAssertEqual(decider.transition(event(.keyDown, 49, repeatKey: true)).action, .none)
        XCTAssertEqual(decider.transition(event(.keyDown, 49)).action, .none)
        XCTAssertEqual(decider.transition(event(.keyUp, 49)).action, .released)
        XCTAssertEqual(decider.transition(event(.keyUp, 49)).action, .none)
    }

    func testEscapeCancelsOnceAndSuppressesItsRelease() {
        var decider = HotkeyDecider()
        _ = decider.transition(event(.flagsChanged, 61, flags: option))
        XCTAssertEqual(decider.transition(event(.keyDown, 53)), HotkeyDecision(action: .cancel, suppress: true))
        XCTAssertEqual(decider.transition(event(.keyDown, 53, repeatKey: true)).action, .none)
        XCTAssertEqual(decider.transition(event(.keyUp, 53)), HotkeyDecision(action: .none, suppress: true))
        XCTAssertEqual(decider.transition(event(.keyDown, 53)), HotkeyDecision(action: .none, suppress: false))
    }

    func testCancelledModifierReleaseWithOtherSideHeldCannotManufacturePress() {
        var decider = HotkeyDecider()
        _ = decider.transition(event(.flagsChanged, 61, flags: option))
        _ = decider.transition(event(.flagsChanged, 58, flags: option))
        _ = decider.transition(event(.keyDown, 53))
        XCTAssertEqual(decider.transition(event(.flagsChanged, 61, flags: option)).action, .none)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 61, flags: option)).action, .pressed)
    }

    func testCancelledOrdinaryKeyMustBeReleasedBeforeAnotherPress() {
        var decider = HotkeyDecider(hotkey: Hotkey(keycode: 49))
        _ = decider.transition(event(.keyDown, 49))
        _ = decider.transition(event(.keyDown, 53))
        XCTAssertEqual(decider.transition(event(.keyDown, 49)).action, .none)
        XCTAssertEqual(decider.transition(event(.keyUp, 49)).action, .none)
        XCTAssertEqual(decider.transition(event(.keyDown, 49)).action, .pressed)
    }

    func testConfigurableModifierUsesItsOwnPhysicalSide() {
        var decider = HotkeyDecider(hotkey: Hotkey(keycode: 60, modifierFlag: .maskShift))
        let shift = CGEventFlags.maskShift.rawValue
        XCTAssertEqual(decider.transition(event(.flagsChanged, 56, flags: shift)).action, .none)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 60, flags: shift)).action, .pressed)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 60, flags: shift)).action, .released)
    }

    func testResetClearsHoldAndEscapeSuppression() {
        var decider = HotkeyDecider()
        _ = decider.transition(event(.flagsChanged, 61, flags: option))
        _ = decider.transition(event(.keyDown, 53))
        decider.reset()
        XCTAssertFalse(decider.transition(event(.keyUp, 53)).suppress)
        XCTAssertEqual(decider.transition(event(.flagsChanged, 61, flags: option)).action, .pressed)
    }

    func testListenerDeliversSynchronousOrderedActionsAndResetsOnStop() {
        let tap = FakeHotkeyTap()
        let listener = HotkeyListener(tap: tap)
        var actions: [HotkeyAction] = []
        listener.onAction = { actions.append($0) }
        XCTAssertTrue(listener.start())
        XCTAssertTrue(listener.start())
        XCTAssertEqual(tap.starts, 1)
        _ = tap.send(event(.flagsChanged, 61, flags: option))
        _ = tap.send(event(.flagsChanged, 61))
        XCTAssertEqual(actions, [.pressed, .released])
        _ = tap.send(event(.flagsChanged, 61, flags: option))
        listener.stop()
        listener.stop()
        XCTAssertEqual(tap.stops, 1)
        XCTAssertTrue(listener.start())
        _ = tap.send(event(.flagsChanged, 61, flags: option))
        XCTAssertEqual(actions, [.pressed, .released, .pressed, .pressed])
        listener.stop()
    }

    func testListenerReenablesDisabledTapAndRetriesFailedStart() {
        let tap = FakeHotkeyTap()
        tap.succeeds = false
        let listener = HotkeyListener(tap: tap)
        XCTAssertFalse(listener.start())
        tap.succeeds = true
        XCTAssertTrue(listener.start())
        XCTAssertFalse(tap.send(event(.tapDisabledByTimeout, 0)))
        XCTAssertFalse(tap.send(event(.tapDisabledByUserInput, 0)))
        XCTAssertEqual(tap.enables, 2)
        listener.stop()
    }

    func testChangingHotkeyKeepsTapRunningAndCancelsOutstandingHold() {
        let tap = FakeHotkeyTap()
        let listener = HotkeyListener(tap: tap)
        var actions: [HotkeyAction] = []
        listener.onAction = { actions.append($0) }
        XCTAssertTrue(listener.start())
        _ = tap.send(event(.flagsChanged, 61, flags: option))
        listener.setHotkey(Hotkey(keycode: 49))
        _ = tap.send(event(.flagsChanged, 61))
        _ = tap.send(event(.keyDown, 49))
        _ = tap.send(event(.keyUp, 49))
        XCTAssertEqual(actions, [.pressed, .cancel, .pressed, .released])
        XCTAssertEqual(tap.starts, 1)
        XCTAssertEqual(tap.stops, 0)
        listener.stop()
    }

    func testSelectingSameHotkeyDoesNotResetAnOutstandingHold() {
        let tap = FakeHotkeyTap()
        let listener = HotkeyListener(tap: tap)
        var actions: [HotkeyAction] = []
        listener.onAction = { actions.append($0) }
        XCTAssertTrue(listener.start())
        _ = tap.send(event(.flagsChanged, 61, flags: option))
        listener.setHotkey(.rightOption)
        _ = tap.send(event(.flagsChanged, 61))
        XCTAssertEqual(actions, [.pressed, .released])
        listener.stop()
    }

    func testListenerDestructionStopsTapAndLateCallbackIsHarmless() {
        let tap = FakeHotkeyTap()
        var listener: HotkeyListener? = HotkeyListener(tap: tap)
        XCTAssertTrue(listener!.start())
        let lateCallback = tap.handler
        listener = nil
        XCTAssertEqual(tap.stops, 1)
        XCTAssertFalse(lateCallback?(event(.flagsChanged, 61, flags: option)) ?? true)
    }
}

@MainActor
private final class FakeHotkeyTap: HotkeyTap {
    var handler: (@MainActor (HotkeyEventSnapshot) -> Bool)?
    var starts = 0
    var stops = 0
    var enables = 0
    var succeeds = true
    func start(handler: @escaping @MainActor (HotkeyEventSnapshot) -> Bool) -> Bool {
        starts += 1
        guard succeeds else { return false }
        self.handler = handler
        return true
    }
    func stop() { stops += 1; handler = nil }
    func enable() { enables += 1 }
    func send(_ event: HotkeyEventSnapshot) -> Bool { handler?(event) ?? false }
}
