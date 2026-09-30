import CoreGraphics
import Testing
@testable import sAId

struct HotkeyControllerBridgeTests {
    @Test(.timeLimit(.minutes(1))) func canceledListenerHoldWithoutReleaseAllowsNextDictation() async {
        let rig = ControllerRig(), controller = rig.controller()
        await rig.capture.configure(chunks: [[Float](repeating: 0.1, count: 4000)])
        await controller.setModelReadiness(.ready)
        var decider = HotkeyDecider()
        func event(_ type: CGEventType, _ keycode: UInt16, flags: UInt64 = 0) -> HotkeyEventSnapshot {
            HotkeyEventSnapshot(typeRawValue: type.rawValue, keycode: keycode, flagsRawValue: flags, isAutoRepeat: false)
        }
        let press = event(.flagsChanged, 61, flags: CGEventFlags.maskAlternate.rawValue)
        HotkeyControllerBridge.send(decider.transition(press).action, to: controller, target: "canceled.app")
        await controller.configure() // Acknowledged mailbox barrier, no hardware.
        let cancel = decider.transition(event(.keyDown, 53)).action
        #expect(cancel == .cancel)
        HotkeyControllerBridge.send(cancel, to: controller)
        await controller.configure()
        // The real decider does not emit .released for an already canceled hold.
        #expect(decider.transition(event(.flagsChanged, 61)).action == .none)
        await rig.capture.configure(chunks: [[Float](repeating: 0.1, count: 4000)])
        HotkeyControllerBridge.send(decider.transition(press).action, to: controller, target: "fresh.app")
        HotkeyControllerBridge.send(decider.transition(event(.flagsChanged, 61)).action, to: controller)
        await controller.configure()
        let starts = await rig.capture.starts.values
        #expect(starts.count == 2)
        if starts.count == 2 {
            await rig.history.waitForCount(1)
            let entries = await rig.history.values
            #expect(entries.count == 1)
            #expect(entries.first?.targetAppID == "fresh.app")
            #expect(entries.first?.source == .final)
            #expect(entries.first?.text == "Final words")
        }
        await controller.shutdown()
    }
}
