import ApplicationServices
import XCTest
@testable import sAId

@MainActor
final class FocusedInputSecurityTests: XCTestCase {
    func testOnlyRecognizedTextControlsCanOverrideGlobalSecureInput() {
        let cases: [(InputAttributeValue, InputAttributeValue, FocusedInputSecurity)] = [
            (.string("AXTextField"), .absent, .ordinaryText),
            (.string("AXTextArea"), .string(""), .ordinaryText),
            (.string("AXTextField"), .string("AXSearchField"), .ordinaryText),
            (.string("AXTextArea"), .string("AXTextEntryArea"), .ordinaryText),
            (.string("AXTextField"), .string("AXUnknown"), .ordinaryText),
            (.string("AXTextField"), .string("AXSecureTextField"), .secure),
            (.string("AXTextField"), .string("CustomPasswordEntry"), .secure),
            (.unavailable, .string("AXSecureTextField"), .secure),
            (.string("AXGroup"), .absent, .unverified),
            (.string("AXWebArea"), .absent, .unverified),
            (.string("AXTextField"), .unavailable, .unverified),
            (.string("AXTextField"), .string("CustomEntry"), .unverified),
            (.absent, .absent, .unverified),
            (.unavailable, .absent, .unverified)
        ]
        for (role, subrole, expected) in cases {
            XCTAssertEqual(FocusedInputSecurity.classify(role: role, subrole: subrole), expected,
                           "role: \(role), subrole: \(subrole)")
        }
    }

    func testAXReadFailureIsNotMistakenForAnAbsentSubrole() {
        XCTAssertEqual(InputAttributeValue.decode(nil, error: .attributeUnsupported), .absent)
        XCTAssertEqual(InputAttributeValue.decode(nil, error: .noValue), .absent)
        XCTAssertEqual(InputAttributeValue.decode(nil, error: .cannotComplete), .unavailable)
        XCTAssertEqual(InputAttributeValue.decode(nil, error: .apiDisabled), .unavailable)
        XCTAssertEqual(InputAttributeValue.decode(nil, error: .success), .unavailable)
        XCTAssertEqual(InputAttributeValue.decode(kCFBooleanFalse, error: .success), .unavailable)
        XCTAssertEqual(InputAttributeValue.decode("AXSecureTextField" as CFString, error: .success),
                       .string("AXSecureTextField"))
    }

    func testReadsCurrentFocusOnEveryCheckWithoutRetainingPasswordState() {
        let access = FakeFocusedInputAccess()
        let reader = FocusedInputInspector(access: access)
        access.subrole = .string("AXSecureTextField")
        XCTAssertEqual(reader.read(), .secure)
        access.subrole = .absent
        XCTAssertEqual(reader.read(), .ordinaryText)
        access.role = .string("AXWebArea")
        XCTAssertEqual(reader.read(), .unverified)
    }

    func testElementAndApplicationChangesDuringMetadataReadRejectStaleFocus() {
        let access = FakeFocusedInputAccess()
        let reader = FocusedInputInspector(access: access)
        access.onAttribute = { access.element = 2 }
        XCTAssertEqual(reader.read(), .focusChanged)
        access.onAttribute = { access.frontmost = 8 }
        XCTAssertEqual(reader.read(), .focusChanged)
    }

    func testWrongOwnerMissingFocusAndFailedSubroleRemainUnverified() {
        let access = FakeFocusedInputAccess()
        let reader = FocusedInputInspector(access: access)
        access.owner = 99
        XCTAssertEqual(reader.read(), .unverified)
        access.owner = 7
        access.element = nil
        XCTAssertEqual(reader.read(), .unverified)
        access.element = 1
        access.subrole = .unavailable
        XCTAssertEqual(reader.read(), .unverified)
        access.frontmost = nil
        XCTAssertEqual(reader.read(), .unverified)
    }
}

@MainActor
private final class FakeFocusedInputAccess: FocusedInputAccess {
    var frontmost: pid_t? = 7
    var owner: pid_t? = 7
    var element: Int? = 1
    var role = InputAttributeValue.string("AXTextField")
    var subrole = InputAttributeValue.absent
    var onAttribute: (() -> Void)?
    func frontmostPID() -> pid_t? { frontmost }
    func focusedElement(in pid: pid_t) -> Int? { element }
    func processID(of element: Int) -> pid_t? { owner }
    func attribute(_ attribute: InputMetadataAttribute, of element: Int) -> InputAttributeValue {
        onAttribute?()
        return attribute == .role ? role : subrole
    }
    func sameElement(_ lhs: Int, _ rhs: Int) -> Bool { lhs == rhs }
}
