import Foundation
import XCTest
@testable import sAId

final class PostProcessTests: XCTestCase {
    func testDefaultPipeline() {
        let pp = PostProcess()
        XCTAssertEqual(pp.apply("um hello tvw"), "Hello TVW")
        XCTAssertEqual(pp.apply("it is, you know, fine"), "It is fine")
        XCTAssertEqual(pp.apply("mimo live uses ndi and live bus for invintus"), "mimoLive uses NDI and LAIveBus for Invintus")
        XCTAssertEqual(pp.apply("I like cats"), "I like cats")
    }

    func testProtectedTokensSurviveEveryStage() {
        let pp = PostProcess(corrections: [.init(from: "said", to: "SAID"), .init(from: "123", to: "one"), .init(from: "um", to: "bad")], fillers: ["um"])
        XCTAssertEqual(pp.apply("see org.tvw.said and https://x.y/um"), "See org.tvw.said and https://x.y/um")
        XCTAssertEqual(pp.apply("said_um said/um 123 1.23 um2 https://x.y/um?a=123"), "said_um said/um 123 1.23 um2 https://x.y/um?a=123")
        XCTAssertEqual(pp.apply("https://x.y/um  123"), "https://x.y/um 123")
        XCTAssertEqual(pp.apply("__SAID_PROTECTED_0__"), "__SAID_PROTECTED_0__")
    }

    func testUnicodeWholeWordsAndLongestPhrase() {
        let pp = PostProcess(corrections: [.init(from: "live", to: "LIVE"), .init(from: "mimo live", to: "mimoLive"), .init(from: "café", to: "COFFEE"), .init(from: "um", to: "X")], fillers: [])
        XCTAssertEqual(pp.apply("mimo   live café caféine écafé umé"), "mimoLive COFFEE caféine écafé umé")
        XCTAssertEqual(pp.apply("cafe\u{301} um\u{301}"), "Cafe\u{301} um\u{301}")
    }

    func testReplacementIsLiteralAndKeepsCasing() {
        let pp = PostProcess(corrections: [.init(from: "mimo live", to: "mimoLive"), .init(from: "cash", to: #"$1\path"#), .init(from: "hello", to: "um")], fillers: ["um"])
        XCTAssertEqual(pp.apply("mimo live"), "mimoLive")
        XCTAssertEqual(pp.apply("cash"), #"$1\path"#)
        XCTAssertEqual(pp.apply("hello"), "um")
        XCTAssertEqual(pp.apply("iPhone works"), "iPhone works")
    }

    func testFillersPunctuationWhitespaceAndTrailingSpace() {
        let pp = PostProcess(corrections: [], fillers: ["um", "uh", "you know"], trailingSpace: true)
        XCTAssertEqual(pp.apply(" um,  hello   . "), "Hello. ")
        XCTAssertEqual(pp.apply("um, uh"), "")
        XCTAssertEqual(pp.apply("um."), "")
        XCTAssertEqual(pp.apply(". um, hello"), "Hello ")
        XCTAssertEqual(pp.apply("  \n "), "")
        XCTAssertEqual(pp.apply("uh-huh and album"), "Uh-huh and album ")
        XCTAssertEqual(PostProcess(corrections: [], fillers: []).apply("hello um"), "Hello um")
        XCTAssertEqual(PostProcess(corrections: [.init(from: " ", to: "bad")], fillers: [""]).apply("hello"), "Hello")
    }

    func testStoreMissingRoundTripEmptyAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/corrections.json")
        let store = CorrectionsStore(fileURL: url)
        XCTAssertEqual(try store.load(), Correction.defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let rules = [Correction(from: "word", to: #"$1\path"#)]
        try store.save(rules)
        XCTAssertEqual(try store.load(), rules)
        try store.save([])
        XCTAssertEqual(try store.load(), [])
        let corrupt = Data("{not json}".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertTrue(CorrectionsStore.defaultURL.path.hasSuffix("sAId/corrections.json"))
    }

    func testWrappedSingleLabelURLsStayProtected() {
        let pp = PostProcess(corrections: [.init(from: "localhost", to: "LOCALHOST")], fillers: ["um"])
        XCTAssertEqual(pp.apply("(https://um)"), "(https://um)")
        XCTAssertEqual(pp.apply("(https://localhost)"), "(https://localhost)")
        XCTAssertEqual(pp.apply("\"https://um\""), "\"https://um\"")
        XCTAssertEqual(pp.apply("see (https://localhost) and \"https://um\""), "See (https://localhost) and \"https://um\"")
    }

    func testFillerPunctuationPreservesMeaningfulSeparators() {
        let pp = PostProcess(corrections: [], fillers: ["um", "you know"])
        XCTAssertEqual(pp.apply("hello, um."), "Hello.")
        XCTAssertEqual(pp.apply("note: um, hello"), "Note: hello")
        XCTAssertEqual(pp.apply("note; um, hello"), "Note; hello")
        XCTAssertEqual(pp.apply("um!"), "")
        XCTAssertEqual(pp.apply("um?"), "")
        XCTAssertEqual(pp.apply("hello, um!"), "Hello!")
        XCTAssertEqual(pp.apply("it is, you know, fine"), "It is fine")
    }

    func testLongestCorrectionUsesNormalizedWhitespace() {
        let pp = PostProcess(corrections: [.init(from: "live       ", to: "LIVE"), .init(from: "mimo live", to: "mimoLive")], fillers: [])
        XCTAssertEqual(pp.apply("mimo live"), "mimoLive")
        XCTAssertEqual(pp.apply("mimo   live"), "mimoLive")
    }

    func testValuesAreSendable() {
        func requireSendable<T: Sendable>(_ value: T) {}
        requireSendable(PostProcess())
        requireSendable(Correction(from: "a", to: "b"))
        requireSendable(CorrectionsStore())
    }
}
