import AppKit
import ApplicationServices

/// Only security metadata leaves the Accessibility boundary; no field contents are read.
enum FocusedInputSecurity: String, Sendable {
    case ordinaryText, secure, unverified, focusChanged

    static func classify(role: InputAttributeValue, subrole: InputAttributeValue) -> Self {
        if case .string(let value) = subrole {
            let lower = value.lowercased()
            if lower.contains("secure") || lower.contains("password") { return .secure }
        }
        guard case .string(let role) = role,
              [kAXTextFieldRole as String, kAXTextAreaRole as String].contains(role) else { return .unverified }
        switch subrole {
        case .absent: return .ordinaryText
        case .string(let value):
            return ["", kAXUnknownSubrole as String, kAXSearchFieldSubrole as String,
                    "AXTextEntryArea"].contains(value) ? .ordinaryText : .unverified
        case .unavailable: return .unverified
        }
    }

    @MainActor static func current() -> Self {
        FocusedInputInspector(access: SystemFocusedInputAccess()).read()
    }
}

enum InputAttributeValue: Equatable {
    case string(String), absent, unavailable

    static func decode(_ value: CFTypeRef?, error: AXError) -> Self {
        if error == .attributeUnsupported || error == .noValue { return .absent }
        guard error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID(),
              let string = value as? String else { return .unavailable }
        return .string(string)
    }
}

enum InputMetadataAttribute { case role, subrole }

/// Tests replace only native application/AX messaging, never the classification policy.
@MainActor
protocol FocusedInputAccess {
    associatedtype Element
    func frontmostPID() -> pid_t?
    func focusedElement(in pid: pid_t) -> Element?
    func processID(of element: Element) -> pid_t?
    func attribute(_ attribute: InputMetadataAttribute, of element: Element) -> InputAttributeValue
    func sameElement(_ lhs: Element, _ rhs: Element) -> Bool
}

@MainActor
struct FocusedInputInspector<Access: FocusedInputAccess> {
    let access: Access

    func read() -> FocusedInputSecurity {
        guard let pid = access.frontmostPID(), pid > 0,
              let element = access.focusedElement(in: pid),
              access.processID(of: element) == pid else { return .unverified }
        let subrole = access.attribute(.subrole, of: element)
        let role = access.attribute(.role, of: element)
        // Never authorize delivery from metadata belonging to a control that lost focus.
        guard let current = access.focusedElement(in: pid), access.sameElement(element, current),
              access.frontmostPID() == pid else { return .focusChanged }
        return .classify(role: role, subrole: subrole)
    }
}

@MainActor
private struct SystemFocusedInputAccess: FocusedInputAccess {
    // Per-object only; changing the process-wide timeout would affect unrelated AX clients.
    private let timeout: Float = 0.05

    func frontmostPID() -> pid_t? {
        guard AXIsProcessTrusted() else { return nil } // Preflight only, never request access here.
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func focusedElement(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, timeout) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement // Validated CF type above.
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return nil }
        return element
    }

    func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }

    func attribute(_ attribute: InputMetadataAttribute, of element: AXUIElement) -> InputAttributeValue {
        let name = attribute == .role ? kAXRoleAttribute : kAXSubroleAttribute
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return .decode(value, error: error)
    }

    func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { CFEqual(lhs, rhs) }
}

/// Allowlisted diagnostics retain no element, process, field value or target identifiers.
struct InsertionSecurityCheck: Sendable {
    let globalSecureInput: Bool
    let focusedInput: FocusedInputSecurity

    var refusal: TextInsertionError? {
        switch focusedInput {
        case .secure: .secureInput
        case .focusChanged: .focusChanged
        case .ordinaryText: nil
        case .unverified: globalSecureInput ? .secureInputUnverified : nil
        }
    }

    var diagnosticText: String {
        "Last insertion security: global=\(globalSecureInput), focused=\(focusedInput.rawValue), decision=\(refusal?.diagnosticCategory ?? "allowed")"
    }
}
