import CoreAudio
import XCTest
@testable import sAId

final class AudioDeviceLookupTests: XCTestCase {
    func testSelectedUIDUsesQualifierAndDeviceIDOutputContract() throws {
        // The real API reports !siz when an AudioValueTranslation is used as output.
        let id = try SystemAudioBackend.resolveDevice(uid: "fixture-input", readProperty: {
            object, address, qualifierSize, qualifier, outputSize, output in
            guard object == kAudioObjectSystemObject,
                  address.pointee.mSelector == kAudioHardwarePropertyTranslateUIDToDevice,
                  address.pointee.mScope == kAudioObjectPropertyScopeGlobal,
                  address.pointee.mElement == kAudioObjectPropertyElementMain else {
                return kAudioHardwareUnknownPropertyError
            }
            guard qualifierSize == MemoryLayout<CFString>.size, let qualifier,
                  outputSize.pointee == MemoryLayout<AudioDeviceID>.size else {
                return kAudioHardwareBadPropertySizeError
            }
            guard qualifier.load(as: CFString.self) as String == "fixture-input" else {
                return kAudioHardwareIllegalOperationError
            }
            output.storeBytes(of: AudioDeviceID(42), as: AudioDeviceID.self)
            return noErr
        })
        XCTAssertEqual(id, 42)
    }

    func testMissingExplicitDeviceDoesNotSilentlyUseDefault() {
        XCTAssertThrowsError(try SystemAudioBackend.resolveDevice(uid: "missing-input", readProperty: {
            _, _, _, _, size, output in
            size.pointee = UInt32(MemoryLayout<AudioDeviceID>.size)
            output.storeBytes(of: AudioDeviceID(kAudioObjectUnknown), as: AudioDeviceID.self)
            return noErr
        })) { XCTAssertEqual($0 as? AudioCaptureError, .deviceUnavailable) }
    }

    func testNativeErrorIsPreserved() {
        XCTAssertThrowsError(try SystemAudioBackend.resolveDevice(uid: "fixture-input", readProperty: {
            _, _, _, _, _, _ in kAudioHardwareIllegalOperationError
        })) { XCTAssertEqual($0 as? AudioCaptureError, .coreAudio(kAudioHardwareIllegalOperationError)) }
    }

    func testUnexpectedOutputByteCountIsRejected() {
        XCTAssertThrowsError(try SystemAudioBackend.resolveDevice(uid: "fixture-input", readProperty: {
            _, _, _, _, size, output in
            output.storeBytes(of: AudioDeviceID(42), as: AudioDeviceID.self)
            size.pointee = 2
            return noErr
        })) { XCTAssertEqual($0 as? AudioCaptureError, .coreAudio(kAudioHardwareBadPropertySizeError)) }
    }

    func testAvailableDeviceUIDsResolveUsingNativeMetadataOnly() throws {
        guard ProcessInfo.processInfo.environment["SAID_AUDIO_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Opt in to read-only Core Audio device metadata checks")
        }
        let devices = Microphones.available()
        guard !devices.isEmpty else { throw XCTSkip("No input devices available on this host") }
        for device in devices {
            let id = try SystemAudioBackend.resolveDevice(uid: device.id)
            XCTAssertNotEqual(id, kAudioObjectUnknown)
            // Confirm identity by reading metadata back; never start an engine or request capture.
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            var uid = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &uid) {
                AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
            }
            XCTAssertEqual(status, noErr)
            XCTAssertTrue(uid as String == device.id, "Resolved device must have the requested UID")
        }
    }
}
