import AppKit
import AVFoundation
import ApplicationServices

struct PermissionStatus: Equatable, Sendable {
    var microphone: Bool
    var inputMonitoring: Bool
    var accessibility: Bool
    var allGranted: Bool { microphone && inputMonitoring && accessibility }
    static let unknown = PermissionStatus(microphone: false, inputMonitoring: false, accessibility: false)
}
struct AppReadiness: Sendable {
    let enabled: Bool
    let permissions: PermissionStatus
    let model: ModelReadiness
    var canDictate: Bool { enabled && permissions.allGranted && model == .ready }
}
enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone = "Microphone", inputMonitoring = "Input Monitoring", accessibility = "Accessibility"
    var id: String { rawValue }
    var settingsPane: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        }
    }
    func granted(in status: PermissionStatus) -> Bool {
        switch self {
        case .microphone: status.microphone
        case .inputMonitoring: status.inputMonitoring
        case .accessibility: status.accessibility
        }
    }
}
@MainActor
enum SystemPermissions {
    /// Read-only preflight. Health polling never prompts for permissions.
    static func check() -> PermissionStatus {
        PermissionStatus(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                         inputMonitoring: CGPreflightListenEventAccess(), accessibility: AXIsProcessTrusted())
    }
    static func request(_ permission: PermissionKind) async {
        switch permission {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .inputMonitoring: _ = CGRequestListenEventAccess()
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
    static func openSettings(_ permission: PermissionKind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
