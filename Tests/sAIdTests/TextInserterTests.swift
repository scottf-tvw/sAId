import CoreGraphics
import Foundation
import XCTest
@testable import sAId

@MainActor
final class TextInserterTests: XCTestCase {
    private let rich: [[String: Data]] = [
        ["public.utf8-plain-text": Data("old".utf8), "public.rtf": Data([1, 2, 3])],
        ["public.png": Data([0, 255]), "custom.type": Data()]
    ]

    func testRestoresEveryItemAndRepresentationAfterPaste() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        var duringPaste: [[String: Data]] = []
        events.onPost = { duringPaste = board.items }
        var duration: Duration?
        let sink = make(board, events, delay: { duration = $0 })
        try await sink.insert("New text ")
        XCTAssertEqual(duringPaste, [["public.utf8-plain-text": Data("New text ".utf8)]])
        XCTAssertEqual(board.items, rich)
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
        XCTAssertEqual(duration, .milliseconds(150))
    }

    func testRestoresEmptyClipboard() async throws {
        let board = FakeInsertionPasteboard([]), events = FakeInsertionEvents()
        try await make(board, events).insert("text")
        XCTAssertEqual(board.items, [])
        XCTAssertEqual(board.clears, 2)
    }

    func testSnapshotFailureDoesNotClearClipboard() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        board.readFailure = true
        await expect(.snapshotFailed) { try await self.make(board, events, fallback: false).insert("text") }
        XCTAssertEqual(board.items, rich)
        XCTAssertEqual(board.clears, 0)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testNativeNilItemsCannotBecomeEmptySnapshot() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        // Exercise the same nil-result interpretation as the native adapter. There is no
        // fallback to a types read: nil items are unreadable even when metadata is also nil.
        board.readOverride = { try SystemInsertionPasteboard.materialize(nil) }
        await expect(.snapshotFailed) { try await self.make(board, events, fallback: false).insert("text") }
        XCTAssertEqual(board.items, rich)
        XCTAssertEqual(board.clears, 0)
        XCTAssertEqual(board.writes, 0)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testNativeNilItemsCanFallbackWithoutMutatingClipboard() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        board.readOverride = { try SystemInsertionPasteboard.materialize(nil) }
        try await make(board, events).insert("text")
        XCTAssertEqual(board.items, rich)
        XCTAssertEqual(board.clears, 0)
        XCTAssertEqual(board.writes, 0)
        XCTAssertEqual(events.posted, ["unicode0"])
    }

    func testNativeEmptyItemsRemainValidEmptySnapshot() async throws {
        let board = FakeInsertionPasteboard([]), events = FakeInsertionEvents()
        board.readOverride = { try SystemInsertionPasteboard.materialize([]) }
        try await make(board, events, fallback: false).insert("text")
        XCTAssertEqual(board.items, [])
        XCTAssertEqual(board.clears, 2)
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
    }

    func testClipboardChangingDuringSnapshotIsNotOverwritten() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        board.onRead = { board.externalCopy("new copy") }
        await expect(.clipboardChanged) { try await self.make(board, events).insert("text") }
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("new copy".utf8)]])
        XCTAssertEqual(board.clears, 0)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testWriteFailureRestoresClipboardBeforeThrowing() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        board.failedWrites = [1]
        await expect(.clipboardWriteFailed) { try await self.make(board, events, fallback: false).insert("text") }
        XCTAssertEqual(board.items, rich)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testEventCreationFailureLeavesClipboardIntact() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        events.pasteError = .eventCreationFailed
        await expect(.eventCreationFailed) { try await self.make(board, events, fallback: false).insert("text") }
        XCTAssertEqual(board.items, rich)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testPermissionFailureDoesNotAttemptFallback() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        events.pasteError = .permissionUnavailable
        await expect(.permissionUnavailable) { try await self.make(board, events).insert("text") }
        XCTAssertEqual(board.clears, 0)
        XCTAssertEqual(events.unicodePreparations, 0)
    }

    func testCancellationDuringDelayStillRestoresClipboard() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let gate = InsertionDelayGate()
        let sink = make(board, events, delay: { _ in try await gate.wait() })
        let insertion = Task { try await sink.insert("text") }
        await gate.entered()
        insertion.cancel()
        gate.release()
        do { try await insertion.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(board.items, rich)
        XCTAssertEqual(events.unicodePreparations, 0)
    }

    func testNewExternalClipboardSurvivesCleanup() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        try await make(board, events, delay: { _ in board.externalCopy("new copy") }).insert("text")
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("new copy".utf8)]])
        XCTAssertEqual(board.clears, 1)
    }

    func testConcurrentRequestIsRejectedUntilCleanupFinishes() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let gate = InsertionDelayGate()
        let sink = make(board, events, delay: { _ in try await gate.wait() })
        let first = Task { try await sink.insert("first") }
        await gate.entered()
        await expect(.insertionInProgress) { try await sink.insert("second") }
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
        gate.release()
        try await first.value
        XCTAssertEqual(board.items, rich)
    }

    func testSeparateInserterCannotDeliverDuringAnotherClipboardTransaction() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let gate = InsertionDelayGate()
        let firstSink = make(board, events, delay: { _ in try await gate.wait() })
        let secondSink = make(board, events, strategy: .directUnicode)
        let first = Task { try await firstSink.insert("first") }
        await gate.entered()
        await expect(.insertionInProgress) { try await secondSink.insert("second") }
        gate.release()
        try await first.value
        XCTAssertEqual(board.items, rich)
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
        // Cleanup releases exclusive ownership for both strategies.
        try await secondSink.insert("third")
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp", "unicode0"])
    }

    func testSecureInputRefusesWithoutClipboardOrEvents() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        await expect(.secureInput) { try await self.make(board, events, secure: { true }).insert("text") }
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(board.clears, 0)
        XCTAssertEqual(events.pastePreparations, 0)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testGlobalSecureInputDoesNotLatchAfterLeavingPasswordField() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let field = MutableFocusedInput(.secure)
        let sink = TextInserter(pasteboard: board, events: events,
                                secureInput: { true }, focusedInput: { field.value }, delay: { _ in })
        // One resident inserter, with the global flag held true across every transition.
        for _ in 0..<20 {
            field.value = .secure
            await expect(.secureInput) { try await sink.insert("private") }
            let count = events.posted.count
            field.value = .ordinaryText
            try await sink.insert("ordinary")
            XCTAssertEqual(events.posted.count, count + 2)
            XCTAssertEqual(board.items, rich)
        }
    }

    func testFocusedPasswordRefusesEvenWhenGlobalSecureFlagIsFalse() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let sink = TextInserter(pasteboard: board, events: events,
                                secureInput: { false }, focusedInput: { .secure }, delay: { _ in })
        await expect(.secureInput) { try await sink.insert("private") }
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testUnverifiedFocusWithGlobalSecureInputRefusesWithoutFallbackAndRecovers() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let field = MutableFocusedInput(.unverified)
        let sink = TextInserter(pasteboard: board, events: events,
                                secureInput: { true }, focusedInput: { field.value }, delay: { _ in })
        await expect(.secureInputUnverified) { try await sink.insert("text") }
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(events.unicodePreparations, 0)
        XCTAssertTrue(events.posted.isEmpty)
        field.value = .ordinaryText
        try await sink.insert("recovered")
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
    }

    func testUnverifiedCustomEditorStillWorksWhenGlobalSecureInputIsOff() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let sink = TextInserter(pasteboard: board, events: events,
                                secureInput: { false }, focusedInput: { .unverified }, delay: { _ in })
        try await sink.insert("text")
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
        XCTAssertEqual(board.items, rich)
    }

    func testFocusedPasswordAppearingDuringClipboardWriteRestoresWithoutPosting() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let field = MutableFocusedInput(.ordinaryText)
        board.onWrite = { field.value = .secure }
        let sink = TextInserter(pasteboard: board, events: events,
                                secureInput: { false }, focusedInput: { field.value }, delay: { _ in })
        await expect(.secureInput) { try await sink.insert("text") }
        XCTAssertEqual(board.items, rich)
        XCTAssertTrue(events.posted.isEmpty)
        XCTAssertEqual(events.unicodePreparations, 0)
    }

    func testFocusedPasswordStopsSubsequentUnicodeChunks() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let field = MutableFocusedInput(.ordinaryText)
        events.onPost = { field.value = .secure }
        let sink = TextInserter(pasteboard: board, events: events, strategy: .directUnicode,
                                secureInput: { false }, focusedInput: { field.value }, delay: { _ in })
        await expect(.secureInput) { try await sink.insert("12345678901234567890second") }
        XCTAssertEqual(events.posted, ["unicode0"])
        XCTAssertEqual(board.reads, 0)
    }

    func testChangingFocusRefusesEvenWithGlobalSecurityOffAndReportsLastDecision() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let field = MutableFocusedInput(.ordinaryText)
        board.onWrite = { field.value = .focusChanged }
        let sink = TextInserter(pasteboard: board, events: events,
                                secureInput: { false }, focusedInput: { field.value }, delay: { _ in })
        await expect(.focusChanged) { try await sink.insert("private test content") }
        XCTAssertEqual(board.items, rich)
        XCTAssertTrue(events.posted.isEmpty)
        XCTAssertEqual(events.unicodePreparations, 0)
        XCTAssertEqual(TextInserter.latestSecurityCheck?.focusedInput, .focusChanged)
        XCTAssertEqual(TextInserter.latestSecurityCheck?.globalSecureInput, false)
        XCTAssertEqual(TextInserter.latestSecurityCheck?.refusal, .focusChanged)
    }

    func testClipboardChangedDuringSecurityInspectionIsNotPastedOrOverwritten() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        let field = MutableFocusedInput(.ordinaryText)
        let sink = TextInserter(pasteboard: board, events: events, secureInput: { true }, focusedInput: {
            field.reads += 1
            if field.reads == 2 { board.externalCopy("new external copy") }
            return field.value
        }, delay: { _ in })
        await expect(.clipboardChanged) { try await sink.insert("dictation") }
        XCTAssertEqual(board.items, [["public.utf8-plain-text": Data("new external copy".utf8)]])
        XCTAssertTrue(events.posted.isEmpty)
        XCTAssertEqual(events.unicodePreparations, 0)
    }

    func testCancellationDuringPreEventSecurityInspectionPostsNothingForEitherStrategy() async {
        for strategy in TextInsertionStrategy.allCases {
            let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
            let field = MutableFocusedInput(.ordinaryText)
            let sink = TextInserter(pasteboard: board, events: events, strategy: strategy,
                                    secureInput: { true }, focusedInput: {
                field.reads += 1
                // Unicode also checks before preparing events; cancel in the actual pre-post check.
                if field.reads == (strategy == .clipboardPaste ? 2 : 3) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return field.value
            }, delay: { _ in })
            let insertion = Task { try await sink.insert("canceled dictation") }
            do { try await insertion.value; XCTFail("Expected cancellation for \(strategy)") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(events.posted.isEmpty, "Canceled delivery for \(strategy)")
            XCTAssertEqual(board.items, rich)
        }
    }

    func testSecureInputIsCheckedAgainImmediatelyBeforeDelivery() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        var secure = false
        board.onWrite = { secure = true }
        await expect(.secureInput) { try await self.make(board, events, secure: { secure }).insert("text") }
        XCTAssertEqual(board.items, rich)
        XCTAssertTrue(events.posted.isEmpty)
    }

    func testKnownPreDeliveryFailureFallsBackOnceAfterRestoration() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        board.failedWrites = [1]
        var boardAtDelivery: [[String: Data]] = []
        events.onPost = { boardAtDelivery = board.items }
        try await make(board, events).insert("hello")
        XCTAssertEqual(boardAtDelivery, rich)
        XCTAssertEqual(events.posted, ["unicode0"])
        XCTAssertEqual(events.unicodeChunks, [Array("hello".utf16)])
    }

    func testPostedPasteNeverTriggersUnicodeBasedOnUnknownAcceptance() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        try await make(board, events).insert("ignored by target")
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
        XCTAssertEqual(events.unicodePreparations, 0)
    }

    func testRestoreFailureIsReportedWithoutRetryingDelivery() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        board.failedWrites = [2]
        await expect(.clipboardRestoreFailed) { try await self.make(board, events).insert("text") }
        XCTAssertEqual(events.posted, ["pasteDown", "pasteUp"])
        XCTAssertEqual(events.unicodePreparations, 0)
    }

    func testDirectUnicodeDoesNotAccessClipboard() async throws {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        try await make(board, events, strategy: .directUnicode).insert("hello😀")
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(board.clears, 0)
        XCTAssertEqual(events.pastePreparations, 0)
        XCTAssertEqual(events.unicodeChunks, [Array("hello😀".utf16)])
        XCTAssertEqual(events.posted, ["unicode0"])
    }

    func testUnicodePreparationFailurePostsNothing() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        events.unicodeError = .eventCreationFailed
        await expect(.eventCreationFailed) { try await self.make(board, events, strategy: .directUnicode).insert("text") }
        XCTAssertTrue(events.posted.isEmpty)
        XCTAssertEqual(board.clears, 0)
    }

    func testSecureInputCheckedBeforeEveryUnicodeEvent() async {
        let board = FakeInsertionPasteboard(rich), events = FakeInsertionEvents()
        var secure = false
        events.onPost = { secure = true }
        await expect(.secureInput) {
            try await self.make(board, events, strategy: .directUnicode, secure: { secure })
                .insert("12345678901234567890second")
        }
        XCTAssertEqual(events.posted, ["unicode0"])
    }

    func testUnicodeChunksKeepComposedCharactersAndSurrogatesWhole() {
        XCTAssertEqual(unicodeInsertionChunks(for: "a😀b", maxUTF16UnitsPerEvent: 2), [[97], [0xD83D, 0xDE00], [98]])
        XCTAssertEqual(unicodeInsertionChunks(for: "ae\u{301}b", maxUTF16UnitsPerEvent: 2), [[97], [101, 769], [98]])
        XCTAssertEqual(unicodeInsertionChunks(for: "👩‍💻!", maxUTF16UnitsPerEvent: 2),
                       [[0xD83D, 0xDC69, 0x200D, 0xD83D, 0xDCBB], [33]])
        XCTAssertEqual(unicodeInsertionChunks(for: ""), [])
        XCTAssertEqual(unicodeInsertionChunks(for: "x", maxUTF16UnitsPerEvent: 0), [])
    }

    func testEveryInsertionEventPlanBypassesMatchingHotkey() {
        let paste = InsertionEventPlan.paste
        let unicode = InsertionEventPlan.unicode([[97], [0xD83D, 0xDE00]])
        XCTAssertEqual(paste.map(\.keycode), [9, 9])
        XCTAssertEqual(paste.map(\.keyDown), [true, false])
        XCTAssertEqual(unicode.map(\.unicode), [[97], [0xD83D, 0xDE00]])
        for plan in paste + unicode {
            XCTAssertEqual(plan.sourceUserData, EventOrigin.insertion)
            var decider = HotkeyDecider(hotkey: Hotkey(keycode: plan.keycode))
            let snapshot = HotkeyEventSnapshot(
                typeRawValue: (plan.keyDown ? CGEventType.keyDown : .keyUp).rawValue,
                keycode: plan.keycode, flagsRawValue: plan.flagsRawValue,
                isAutoRepeat: false, sourceUserData: plan.sourceUserData)
            XCTAssertEqual(decider.transition(snapshot), HotkeyDecision(action: .none, suppress: false))
            XCTAssertFalse(decider.active)
        }
    }

    private func make(_ board: FakeInsertionPasteboard, _ events: FakeInsertionEvents,
                      strategy: TextInsertionStrategy = .clipboardPaste, fallback: Bool = true,
                      secure: @escaping @MainActor () -> Bool = { false },
                      delay: @escaping @MainActor (Duration) async throws -> Void = { _ in }) -> TextInserter {
        TextInserter(pasteboard: board, events: events, strategy: strategy,
                     allowsUnicodeFallback: fallback, secureInput: secure,
                     focusedInput: { secure() ? .secure : .unverified }, delay: delay)
    }

    private func expect(_ expected: TextInsertionError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? TextInsertionError, expected) }
    }
}

@MainActor
private final class FakeInsertionPasteboard: InsertionPasteboard {
    var items: [[String: Data]]
    var changeCount = 0
    var reads = 0, clears = 0, writes = 0
    var readFailure = false
    var readOverride: (() throws -> [[String: Data]])?
    var failedWrites: Set<Int> = []
    var onRead: (() -> Void)?
    var onWrite: (() -> Void)?
    init(_ items: [[String: Data]]) { self.items = items }
    func readItems() throws -> [[String: Data]] {
        reads += 1
        if readFailure { throw TextInsertionError.snapshotFailed }
        if let readOverride { return try readOverride() }
        let snapshot = items
        onRead?()
        return snapshot
    }
    func clearContents() -> Int { clears += 1; changeCount += 1; items = []; return changeCount }
    func writeItems(_ items: [[String: Data]]) -> Bool {
        writes += 1
        if failedWrites.contains(writes) { return false }
        self.items = items
        onWrite?()
        return true
    }
    func externalCopy(_ text: String) { changeCount += 1; items = [["public.utf8-plain-text": Data(text.utf8)]] }
}

@MainActor
private final class FakeInsertionEvents: InsertionEvents {
    var pasteError: TextInsertionError?, unicodeError: TextInsertionError?
    var pastePreparations = 0, unicodePreparations = 0
    var unicodeChunks: [[UInt16]] = []
    var posted: [String] = []
    var onPost: (() -> Void)?
    func preparePaste() throws -> [any PreparedInsertionEvent] {
        pastePreparations += 1
        if let pasteError { throw pasteError }
        return [event("pasteDown"), event("pasteUp")]
    }
    func prepareUnicode(_ chunks: [[UInt16]]) throws -> [any PreparedInsertionEvent] {
        unicodePreparations += 1
        unicodeChunks = chunks
        if let unicodeError { throw unicodeError }
        return chunks.indices.map { event("unicode\($0)") }
    }
    private func event(_ name: String) -> FakePreparedEvent {
        FakePreparedEvent { self.posted.append(name); self.onPost?() }
    }
}

@MainActor
private struct FakePreparedEvent: PreparedInsertionEvent {
    let action: () -> Void
    func post() { action() }
}

@MainActor
private final class InsertionDelayGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func wait() async throws {
        if didEnter { return }
        didEnter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer?.resume(); observer = nil
        }
        try Task.checkCancellation()
    }
    func entered() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class MutableFocusedInput {
    var value: FocusedInputSecurity
    var reads = 0
    init(_ value: FocusedInputSecurity) { self.value = value }
}
