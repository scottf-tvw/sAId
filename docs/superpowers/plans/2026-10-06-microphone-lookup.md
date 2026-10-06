# Selected microphone lookup repair

Execute inline with systematic debugging and TDD, then one scoped independent code review. Existing autonomous repair authorization applies; preserve the running app until Scott quits it.

## Evidence and scope

Scott is on the Studio, running1.0.2. His diagnostics show model ready, all permissions true, captureFailed. Read-only unified logs show repeated coreAudio(561211770), FourCC !siz, when starting capture. macOS hardware inventory detects Wireless Mic Rx as default input; sAId preferences explicitly select its UID. No microphone recording/TCC interaction was performed.

Apple's installed AudioHardware.h documents kAudioHardwarePropertyTranslateUIDToDevice: CFString UID in qualifier, AudioDeviceID in property output. Current SystemAudioBackend.resolveDevice instead supplies no qualifier and an AudioValueTranslation as output. This is the concrete size mismatch; device enumeration itself is not the root cause.

## One task

- [ ] Add an injectable Core Audio property-read boundary to the existing resolver without changing its behavior; tests must enforce the documented argument and buffer contract. Observe a selected-device lookup fail with !siz before the fix.
- [ ] Pass the CFString reference as qualifier and a4-byte AudioDeviceID output, validate status/output size/unknown ID. Test known UID, missing device, native error and malformed returned size; preserve explicit-device failure rather than silently selecting a different mic. Default-input behavior is unchanged.
- [ ] Verify a read-only native UID lookup using production resolver and locally enumerated metadata. No AVAudioEngine start, recording, TCC grants, UI input/clipboard or desktop lock. Do not save physical UID in committed docs/tests.
- [ ] Run focused/full tests, build signed1.0.3/build4, get one independent review, fix any material findings. No unrelated model/security/window changes.
- [ ] Stage verified signed app/ZIP, then ask Scott to quit running sAId when ready; install only after exit, no agent relaunch. Push task branch/create/attach PR against main stacked onPR14; no merge/notarization/publicrelease.
- [ ] Update HANDOFF/SMOKE/memory with evidence and user capture retest pending; preserve worktree/evidence. No repeated unchanged suites after passing final build/tests.

Files: Sources/sAId/Audio/SystemAudioBackend.swift; new Tests/sAIdTests/AudioDeviceLookupTests.swift; project.yml; docs. Boundary type mirrors AudioObjectGetPropertyData with synchronous borrowed pointers. No values may escape the call.

Review focus: qualifier pointer/CFString lifetime and exact size; output byte-size validation; nonempty missing UID must refuse without default fallback; native errors retained; tests must avoid real microphone capture. The user's Right Control hotkey is intentional.
