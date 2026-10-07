import Testing
@testable import sAId

struct AppControllerConfigurationTests {
    @Test(.timeLimit(.minutes(1))) func changingInsertionStrategyPreservesCurrentSessionAndUpdatesNext() async {
        let rig = ControllerRig(), controller = rig.controller(), nextSink = ControllerSink()
        await rig.capture.configure(chunks: [[Float](repeating: 0.1, count: 4000)])
        await controller.setModelReadiness(.ready)
        await controller.handle(.pressed)
        controller.sendConfiguration(sink: nextSink, postProcess: PostProcess(corrections: [], fillers: [], trailingSpace: true))
        await controller.handle(.released)
        await rig.history.waitForCount(1)
        #expect(await rig.sink.inputs.values == ["Final words"])
        #expect(await nextSink.inputs.values.isEmpty)
        await rig.capture.configure(chunks: [[Float](repeating: 0.1, count: 4000)])
        await controller.handle(.pressed)
        await controller.handle(.released)
        await rig.history.waitForCount(2)
        #expect(await rig.sink.inputs.values == ["Final words"])
        #expect(await nextSink.inputs.values == ["Final words "])
        await controller.shutdown()
    }
}
