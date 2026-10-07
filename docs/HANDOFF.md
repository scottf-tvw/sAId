# HANDOFF — sAId (updated 2026-10-06)

Read `CLAUDE.md`, the amended design, then the implementation plan. Scott authorized completing the project autonomously and asking for human help only when needed.

## Selected microphone lookup repair (1.0.3 build 4)

Scott is now testing on the **Studio**. His 1.0.2 diagnostics show model ready, all three permissions true, Right Control hotkey, and `captureFailed` before insertion. Read-only app logs repeatedly report `coreAudio(561211770)` (`!siz`, bad property size). macOS detects the DJI Wireless Mic Rx as default input, and the saved sAId preference selects that same device explicitly. The microphone is present; selected-device lookup is broken.

`SystemAudioBackend.resolveDevice` incorrectly used an `AudioValueTranslation` output buffer with no qualifier for `kAudioHardwarePropertyTranslateUIDToDevice`. Apple's installed `AudioHardware.h` documents a CFString UID qualifier and an AudioDeviceID output. The old production resolver reproduced the exact `!siz` error in a read-only native metadata test. The corrected qualifier/output call passes that same native test and validates returned size/status/unknown IDs. A missing explicit device still fails instead of silently capturing from another microphone. System-default capture was unaffected; Scott was given **Settings → Microphone → System default** as an immediate workaround.

Five focused tests pass, including opt-in native metadata resolution and UID identity round trips without starting an audio engine. Full `make test` passes: **200 XCTest cases (3 expected opt-in skips), 12 Swift Testing cases and 15 packaging tests**. The native metadata test was separately enabled and passed; the other two skips are unchanged model checks. Signed Release 1.0.3 build 4 passes signature/resources/architecture/entitlement checks, executable SHA256 `0ee13fa31250fd356d1746d8c79c6bb2f25c0c2ad812379721b658a70db924ef`. Evidence is in `.superpowers/sdd/2026-10-06-microphone-lookup/` (`red.log`, `native-red.log`, `green.log`, `full-test.log`, `release.log`). No microphone capture, TCC request, clipboard/input or GUI action was performed by agents.

Independent review found no issues. [PR #15](https://github.com/scottf-tvw/sAId/pull/15) is open and attached against main, stacked on PR #14. A verified signed app is staged at `/Users/scottfreeman/Downloads/sAId-update-1.0.3.JeKRN7/sAId.app`; the matching local-test ZIP is in the same directory, `sAId-1.0.3-local-test.zip`, SHA256 `074e32b658fab64f6fc2d52d2097f73fba7bd0458142c048c45ab42c0cd9a806`. Extracted signature/resources/executable match were verified; the owned extraction was removed. The archive is not notarized. sAId 1.0.2 is still running at `/Applications/sAId.app`; the async request for Scott to quit is pending. Do not replace it until exit is confirmed. No install or relaunch of 1.0.3 has occurred. Next acceptance is reopening 1.0.3, explicitly selecting Wireless Mic Rx, and dictating with **Right Control**. Native metadata success does not prove audio capture/delivery; those remain Scott's check. Earlier Secure Input recovery, window fit, latency and clipboard acceptance remain pending unless reported.

## Secure Input recovery follow-up (1.0.2 build 3)

Scott reports that after sAId works for a while, every field is rejected as secure. The old inserter used `IsSecureEventInputEnabled()` as the sole test. Apple's SDK documents that this reports Secure Input enabled by **any process**, and [TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) explains how background processes can leave it on. The app did not cache this flag; restarting its model would not correct that policy. The specific process or event causing Scott's global flag to remain enabled is unconfirmed. The optional question about whether restarting sAId helps has not been answered.

The fix reads focused-control Accessibility role/subrole metadata anew before clipboard access and every posted event. Recognized secure/password subroles always refuse. Ordinary text field/area roles with ordinary or absent subroles can insert despite a global true. Unavailable, malformed, custom or container metadata retains the conservative global guard, with a separate “Secure Input active” message instead of falsely asserting a password field. If focus changes during inspection, insertion refuses even when the global flag is false. The same inserter recovers as soon as the next check sees ordinary focus; no permission/model reset is involved. The existing custom-editor behavior is preserved when global Secure Input is off.

Native AX messaging uses 50 ms timeouts on the individual application/element objects; each inspection makes at most four attribute reads and does not change the process-wide AX timeout. It checks frontmost PID and focused identity again before accepting metadata. It never reads field values, selections, labels, titles or URLs, never walks parent containers and never disables Secure Input. Copy diagnostics records the latest insertion check's global boolean, classification and decision; it does not inspect the newly focused menu or retain AX elements/PIDs. Clipboard cleanup, cancellation and security rejection without fallback remain intact.

Regression tests cover 20 repeated secure→ordinary transitions on one inserter while the global flag stays true, secure fields with the global flag false, unreadable-control recovery, clipboard-time and Unicode-chunk focus changes, metadata/error decoding and stale-focus rejection. Independent review identified two delivery races during AX reads; both were reproduced with failing regressions and fixed at `a77f5ec`. Cancellation is rechecked after inspection and clipboard ownership immediately before each paste event. The final full suite passed: **195 XCTest cases (2 expected opt-in skips), 12 Swift Testing cases and 15 packaging tests**. Signed Release 1.0.2 build 3 passed signature/resources/architecture/entitlement checks; executable SHA256 is `de5d518c1028cfac0f24be818ba368ff9d8d1379b3632f739cabc503cb7b19d1`. Evidence and the review are in `.superpowers/sdd/2026-10-03-secure-input-recovery/`; delivery is complete on the Studio. No real desktop/input/microphone/TCC operation or security enable/disable call was performed.

Signed 1.0.2 build 3 is installed and verified at `/Applications/sAId.app` on the Studio, without launch. The executable matches the rebuilt Release; installer lock/staging and the owned ZIP extraction were removed normally. [PR #14](https://github.com/scottf-tvw/sAId/pull/14) is open and attached against main, stacked on PR #13. No merge, notarization or public release was performed.

The final 14 MiB signed local-test ZIP is `/Users/scottfreeman/Downloads/sAId-home-test-1.0.2.ytr3ux/sAId-1.0.2-local-test.zip`, SHA256 `47058266aa7ce1818e693a2788406584bc65092c563c3e460f2fabba6a11021f`. Extracted signature/resources/binary match were verified. The unpublished pre-review archive was removed so it cannot be mistaken for the fixed build. From the home Mini while VPN is connected:

```bash
scp scottfreeman@10.1.16.112:Downloads/sAId-home-test-1.0.2.ytr3ux/sAId-1.0.2-local-test.zip ~/Downloads/
```

Quit sAId, unzip and replace it in Applications, then reopen. Home installation has not been confirmed. All build/test/install/review processes have completed; no idle background tasks remain.

Next human acceptance: after installing the update, repeat ordinary dictation, enter/leave a real password field, then return to ordinary text without restarting sAId. A real password field must still refuse; normal text should resume. If refusal remains, copy diagnostics immediately and report whether the HUD/hotkey still responds. macOS can itself suppress event-tap hotkeys while another process holds Secure Input; this change corrects sAId's insertion policy and cannot promise to disable another app's system protection. Earlier window/latency and clipboard acceptance remain pending unless Scott supplies results.

## Home smoke follow-up (1.0.1 build 2)

Scott reports that live HUD and insertion work on the home Mini, but text feels slow after release and utility windows open shrunken. The delay has not been quantified or reproduced on that machine.

Offscreen AppKit reproduction found that default `NSHostingController.sizingOptions` propagates ideal/min/max sizing when attached, replacing the window's initial content rectangle (the probe observed 1×0). Disabling every option preserved the initial size but erased the minimum on later layout. The fix retains only `.minSize`, constrains the root view's minimum to available screen space, and sets content size after hosting attachment. Settings opens at 660×640 with minimum 600×500; History 640×500/minimum 500×320; Permissions 620×360/minimum 580×320, with scrolling for its explanatory text. These values are bounded by the current screen's visible frame, including title-bar space and a margin; windows remain resizable. Titles and permission checklist lifecycle callbacks are unchanged.

Invisible production-factory probes verified stable initial/minimum geometry and growth to 900×800, Settings and each of its four tab contents (grouped forms/list retain scrolling), empty History, 50 synthetic History entries and Permissions. Access-only changes to expose private tab contents for the scratch probe were restored, and scratch tests were removed before final validation. This is geometry/layout evidence, not Scott's live visual acceptance or a test on another physical display size.

Paced 16 kHz corpus fixtures on the existing resident shared engine measured preview stop 0.00008–0.256 seconds and full final inference 0.217–0.346 seconds. Combined tail after the last feed call returned was 0.270–0.528 seconds. The probe feeds at audio deadlines, but awaits the last feed before timing stop/final; it excludes capture drain, outstanding last-feed work, event mailbox delays, insertion and target acceptance. It does not establish the home Mini's release latency or justify removing native trailing preview decoding or whole-utterance final inference. The 150 ms clipboard-restore delay occurs after event posting. No speed improvement is claimed.

Copy diagnostics now includes the latest completed session's monotonic stage durations and safe outcome/finish-trigger categories: release intake mailbox wait, capture stop/drain, preview drain wait and stop-call duration, whole-utterance final, text processing, final-result mailbox wait and insertion posting/cleanup. On normal release, preview stop is included in the drain wait; failure/cancellation can stop preview partly or wholly earlier, including before release. Do not add stop and drain as independent serial durations. Total timing starts at synchronous release intake (or audio-cap processing) and ends at controller completion, which can include History bookkeeping; it does not measure target acceptance. An omitted stage has no completed measurement. Reports retain no transcript, corrections, clipboard bytes, targets, error strings or machine/network identifiers. They are per controller lifetime and reset with an explicit model reset/relaunch. Cancellation reports follow owned cleanup; queued sessions preserve their own timing and finish origin. No extra per-key tasks were added.

Final `make test` passed: 181 XCTest tests (2 cached-model opt-in skips), 12 Swift Testing tests and 15 packaging tests. After the scoped preview-timing wording review, all five timing tests passed and signed Release 1.0.1 build 2 was rebuilt; the unchanged full suite was not repeated. The rebuilt product passed the existing strict signature/designated-requirement/team, hardened-runtime, arm64, single audio-input entitlement and resource byte checks. Its executable SHA256 is `517b71dde8a7f088f40c8db0947f693bd57e840793651c4fcb4b3a73ba2b815e`. Five deterministic regressions exercise stage boundaries, cancellation/final failure/short tap, queued-session insertion failure, capped-key release and a blocked mailbox. Initial RED evidence and raw layout/fixture logs are in ignored `.superpowers/sdd/2026-09-29-home-smoke-fixes/`; see its `task-1-report.md` for commands and final verification.

Independent review accepted implementation `dbc2577`; its one minor preview-timing wording finding was fixed at `b9f9a68` and accepted in scoped re-review. Parent installed the reviewed Release at `/Applications/sAId.app` on the Studio without launching it. Installed version/build, signature/resources and executable match were verified; the installer lock and owned staging directory were removed normally. Installation evidence is in `final-install.log` and `final-installed-verification.log` beside the review reports. [PR #13](https://github.com/scottf-tvw/sAId/pull/13) is open and attached, stacked on PR #12 against main. No merge, notarization or public release occurred.

The new 14 MiB signed local-test ZIP is `/Users/scottfreeman/Downloads/sAId-home-test-1.0.1.QvUedQ/sAId-1.0.1-local-test.zip`, SHA256 `2656cd706202a1e01925c904098df0239f017870aff4b2fb2a9240503e7e1168`. Its extracted signature/resources and executable match were verified and the owned extraction was removed. Pull it from the home Mini while VPN is connected:

```bash
scp scottfreeman@10.1.16.112:Downloads/sAId-home-test-1.0.1.QvUedQ/sAId-1.0.1-local-test.zip ~/Downloads/
```

Home installation of this update has not been confirmed. Next human check: quit sAId, unzip and replace the old app in Applications, reopen it, confirm diagnostics identifies **1.0.1**, check every Settings tab plus History/Permissions at initial/minimum/grown sizes, then dictate one short utterance and Copy diagnostics immediately after insertion. Supply the stage report with approximate observed delay. Clipboard restoration remains separately untested; test the sentinel before Copy diagnostics deliberately replaces the clipboard. Agents have performed no app launch, real microphone/TCC/clipboard/input or desktop lock.

## Current decision

**Moonshine English Medium Streaming for BOTH live preview and final transcription.** Scott changed the original Qwen choice during this implementation session and supplied the official current-model list:
https://moonshine-voice.readthedocs.io/en/latest/models/available-models/#current-models

Use Swift `.mediumStreaming`, language `en`, one resident actor-owned native model, serialized streaming/final access. Qwen/speech-swift/MLX have been removed. Do not reintroduce them from historical commits. Final output is completed after release, postprocessed, then inserted; live partials remain display-only. No unmeasured accuracy superiority is claimed.

## Workspaces and integration

- Public MIT repo: `github.com/scottf-tvw/sAId`.
- Original checkout `/Volumes/Work/GitDev/sAId` remains on `main`.
- **Active worktree:** `/Users/scottfreeman/.codex/worktrees/said-implementation/sAId`.
- Current branch: `codex/fix-microphone-lookup`, based on `c70bb85` from PR #14. Earlier implementation work is preserved below as history.
- [PR #1](https://github.com/scottf-tvw/sAId/pull/1): baseline menu-bar entry/test target (original engine pin, superseded by the amendment).
- [PR #2](https://github.com/scottf-tvw/sAId/pull/2): pure state machine and async engine protocols.
- [PR #3](https://github.com/scottf-tvw/sAId/pull/3): Moonshine-only dependency/design amendment (review clean).
- [PR #4](https://github.com/scottf-tvw/sAId/pull/4): protected transcript postprocessing; review clean.
- [PR #5](https://github.com/scottf-tvw/sAId/pull/5): ordered audio capture; review clean.
- [PR #6](https://github.com/scottf-tvw/sAId/pull/6): physical hotkey handling; review clean.
- [PR #7](https://github.com/scottf-tvw/sAId/pull/7): clipboard-safe insertion and event-origin handling; review clean.
- [PR #8](https://github.com/scottf-tvw/sAId/pull/8): resident Moonshine preview and verified cache; review clean.
- [PR #9](https://github.com/scottf-tvw/sAId/pull/9): final transcription on the same resident model; review clean.
- [PR #10](https://github.com/scottf-tvw/sAId/pull/10): ordered controller and nonactivating HUD; review clean.
- [PR #11](https://github.com/scottf-tvw/sAId/pull/11): full app shell, settings, History, permission recovery and signed bundle; review clean.
- [PR #12](https://github.com/scottf-tvw/sAId/pull/12): shared benchmark, safe signed packaging and final integration fixes; reviewed and installed.
- [PR #13](https://github.com/scottf-tvw/sAId/pull/13): useful utility window sizes and content-free session stage diagnostics, reviewed and installed as 1.0.1 build 2 on the Studio; home retest pending.
- [PR #14](https://github.com/scottf-tvw/sAId/pull/14): focused-field Secure Input recovery and delivery-race fixes, tested and installed as 1.0.2 build 3 on the Studio; home recovery retest pending.
- [PR #15](https://github.com/scottf-tvw/sAId/pull/15): selected-microphone UID lookup repair, reviewed/tested and staged as 1.0.3 build 4; installation waits for Scott to quit the running Studio app.
- PRs #1–15 remain open and unmerged pending approval. Task 11 is complete at `42419f9`/`1cbf097`; task review and scoped re-review approved. The final whole-branch review and one consolidated fix/re-review wave are complete at `77232c8`: all three requested fixes are accepted, with two nonblocking follow-ups documented below.
- Task 10 app shell/signed bundle is complete at `c35013e`/`a149c35`, base `75185b8`; independent review approved, menu-error fix re-review clean.
- Task 9 controller/HUD is complete at `f1c3b3d`, review clean; 164 strict tests pass with two expected opt-in skips.
- Task 7 Moonshine adapter/cache/preview is complete at `8a01472`, review clean; all 127 strict tests pass with cached-model contracts enabled. Task 8 final transcription is complete at `f1b24cd`, review clean.
- Task 6 insertion is complete and reviewed, commits `7d22f0e`, `96a4f9f`; parent independently verified all 108 tests with strict concurrency and warnings-as-errors.
- Task 5 hotkey handling is complete and reviewed, commits `68af2af`, `04dc44d`; 17 hotkey checks and all 81 tests pass. Review fixed physical-state resynchronization at startup/reconfiguration/recovery.
- Task 4 audio capture is complete and reviewed, commit `8be4fd7`; 12 audio checks and all 64 tests pass. Strict-concurrency build passes; no hardware accessed.
- Task 3 (postprocessing) is complete and reviewed, commits `5205424`, `5b1c41a`; parent independently verified 52 strict-concurrency tests. Wrapped URL, filler punctuation, and normalized correction priority regressions are fixed.
- Merge authorization was requested and remains pending. Continue implementing task branches; don't infer merge approval from the engine-choice discussion.
- Recovery ledger: `.superpowers/sdd/2026-09-29-said-implementation/progress.md` in the active worktree. It contains task commits, reviews, fixes, and preflight rulings. Scratch reports/briefs/logs are ignored and must NOT be force-added to git.
- Durable design corrections: `docs/IMPLEMENTATION-NOTES.md`.

## Completed and verified

1. Task 1: SwiftUI menu-bar placeholder replaces CLI main; module-import smoke test. Baseline review clean.
2. Task 2: checked-Sendable state/reducer/protocols/logging. **41 reducer tests + 1 import test pass** with Swift 6 complete concurrency. Review found and fixed trailing-space loss and readiness recovery reopening capture during outstanding inference; scoped re-review clean. Core implementation commits `1706ef8`, `db96ed5`.
3. Engine amendment: Package.swift now pins **moonshine-swift exactly 0.1.5**; Package.resolved contains that dependency only. Build/test passed with 42 tests. Amendment review passed; PR #3 is open.

4. Task 3: deterministic corrections, fillers, protected tokens, casing and optional trailing space; atomic corrections JSON persistence. Intentional empty rules stay empty; corruption is surfaced without overwriting data. Review clean after one fix round. **52 tests pass** with strict concurrency.

5. Task 4: non-main-actor audio capture, one-shot converter input, stereo downmix, exact resampler drain, ordered stream teardown, device/wake recovery on next press. Pure/synthetic checks pass and review is clean.

6. Task 5: configurable physical hotkey handling, Escape cancellation, ordered main-actor callbacks, owned tap context, and safe recovery with physical-key resynchronization. **81 tests pass** with strict concurrency; review clean after one fix round.

7. Task 6: clipboard-safe insertion and selectable Unicode fallback; restore on cancellation/failure, preserve newer clipboard contents, reject concurrent transactions, refuse secure input. Generated events bypass hotkey handling. Nil native clipboard reads fail before mutation. **108 tests pass**, review clean after one fix round.

The full app shell, settings, persistent History, permission UI and signed Debug bundle are implemented in Task 10. Task 11 packaging, final review and actual `/Applications/sAId.app` Release installation are verified. Hardware acceptance and actual notarization remain pending.

8. Task 7: one resident actor-owned Moonshine model, fresh preview streams, aggregated line updates, explicit stop-time errors, validated atomic downloads and official mirror fallback. **127 tests pass**, including six offline native sessions; review clean.

9. Task 8: final transcription on the same resident runtime, lifecycle/audio validation, cancellation boundaries and recovery after errors. **137 tests pass** with two opt-in skips; offline final suite separately passes all ten tests and six preview→final sessions. Review clean. Final compute time on the bundled clips was approximately 0.30–0.50 seconds; WER matches the preview results.

10. Task 9: ordered controller integrates capture, both Moonshine roles, insertion and History values; cancellation/shutdown await cleanup. Exact sample boundaries, queued physical actions, source/settings snapshots and errors are tested. Nonactivating 44 pt HUD is implemented. **164 tests pass** with two opt-in skips; review clean.

11. Task 10: full app shell and shared stores, permission recovery, coherent per-session settings/insertion changes, model retry/reset with explicit native release, and signed Xcodegen bundle. **164 XCTest cases (two expected opt-in skips) plus 12 Swift Testing cases pass** with complete concurrency and warnings-as-errors. Signed Debug build, arm64/Developer ID/hardened-runtime/audio-input checks and bundled defaults/notices are verified. Independent review approved; the menu save-error visibility observation is fixed and re-reviewed. Extra injected permission-poll lifecycle tests are deferred as a coverage improvement; existing behavior passed review. The app has not been launched. Task 11 later exercised installation only in an owned temporary destination.

## Task 11 verification (2026-09-29)

- Shared `Sources/SaidEngine` module contains the unchanged inference/cache behavior, with narrow public engine/protocol APIs. The app and benchmark use that same implementation. SPM and Xcodegen both compile it once; Xcode's final app target explicitly links the Moonshine package because local static-library targets do not propagate its objects automatically. Exact 0.1.5 pin, per-session controller configuration/sink snapshots, and explicit native reset ownership remain intact.
- `make build` and `make test` pass with complete strict concurrency and warnings as errors: **169 XCTest cases, two expected opt-in skips, 0 failures; 12 Swift Testing cases, 0 failures; 8 Python packaging tests, 0 failures**. Parser tests reject truncated/malformed audio and preserve signed PCM sample values; WER tests cover literal numbers, edits, empty references and corpus weighting. Existing ordering/reset tests pass after extraction.
- `SAID_MODEL_TESTS=1 swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --filter 'MoonshineModelContractTests|MoonshineFinalEngineTests'`: **11 tests, no skips or failures**, including repeated offline preview/final sessions on the resident model.
- Signed Debug and Release `.app` builds pass signature/designated-requirement/team checks, arm64, hardened runtime, exactly the audio-input entitlement, and byte-for-byte bundled default/notices checks. App identity is `org.tvw.said`, version 1.0.0, minimum macOS 15. Apple emits one non-Swift warning that AppIntents metadata extraction is skipped without that framework dependency.
- `make install` was exercised with a real prior signed app at `build/task11-install.c0JAae/Applications/sAId.app`; it built Release, verified the staged copy, replaced the previous app, and never launched it. Resulting executable matches the Release build. The subsequent reviewed actual `/Applications/sAId.app` installation is recorded below.
- An owned copy of the release benchmark at `build/task11-hardened-bench.ogca9L/said-bench` is signed by the same Developer ID with hardened runtime and exactly the app's audio-input entitlement. Its offline inference succeeds; no broader entitlement was needed. This validates native loading under that policy, not GUI/TCC behavior.
- Bash 3.2 packaging tests prove build/generation/copy/signature/extra-entitlement/staged-verification/swap failures preserve the old app; failed rollback retains a recoverable backup. Notary submission failure, non-Accepted status and staple failures leave no final release ZIP. Make/benchmark failures propagate. Release changes the actual staged bundle version, signs/verifies, requires accepted notarization and a validated staple, then archives. No actual notarization or publication was attempted; the Keychain profile remains absent.
- Task 11 packaging review fixes: install backup/publication/rollback and final ZIP publication now use macOS `renamex_np(..., RENAME_EXCL)` through a small C helper compiled with the selected Xcode SDK. A destination appearing immediately before publication or rollback is left untouched; a blocked rollback retains the prior app and reports its recovery path. Installer destination locks fail immediately if occupied, and stale locks require manual recovery after confirming the prior installer is gone. **15 focused packaging/native-helper tests pass**, including deterministic install/rollback/release destination races, fresh-install conflict diagnostics, existing file/directory/symlink rejection, and concurrent native publication with exactly one winner. A new real temporary installation also passes; unchanged Swift/native/full suites were not repeated for this shell/helper correction. See the appended Task 11 fix report and `task-11-races-green.log`.
- Logs and full task report: `.superpowers/sdd/2026-09-29-said-implementation/task-11-report.md` and `task-11-*.log` in the active worktree (ignored local evidence).

Benchmark: `./scripts/bench.sh --preview Tests/Fixtures Tests/Fixtures/transcripts.json` loads one verified cached model in 0.6461 seconds. All files use literal lowercase alphanumeric WER; no reference or number rewriting. Results below are **prerecorded fast-feed compute**, not live microphone/HUD latency or release-to-paste latency.

| Fixture | Edits / reference words (both roles) | WER | Preview compute s | Final compute s |
|---|---:|---:|---:|---:|
| 1272-128104-0000.wav | 0 / 17 | 0 | 1.414844 | 0.410689 |
| 1272-128104-0005.wav | 1 / 18 | 0.055556 | 1.410713 | 0.491978 |
| 1272-128104-0008.wav | 2 / 11 | 0.181818 | 0.564523 | 0.300144 |
| Corpus (19.985 s audio) | 3 / 46 | **0.065217** | **3.390080** | **1.202811** |

The hardened signed copy produced identical edit/reference counts and hypotheses; load/verify 0.6279 seconds, preview total 3.457341 seconds, final total 1.227656 seconds. Three LibriSpeech clips from one speaker are pipeline evidence, not Scott's jargon accuracy. README describes his optional 20-sentence corpus. Empty-reference insertion errors stay in corpus totals; per-file WER is undefined when an empty reference has nonempty output.

## Final review fix wave (2026-09-29)

- Physical Escape now reaches the ordered controller path after key release during finalization/insertion. The listener reads controller-owned cancellation eligibility synchronously, including pending physical presses, so delayed HUD observation or blocked cleanup cannot erase the intent. Idle Escape passes through; generated insertion events bypass processing; Escape during a queued hold still withdraws only that hold.
- At the exact 1,920,000-sample cap, an independent two-second HUD notice warns that capture ended while frozen preview/finalization continues. Existing timer/session identities reject stale expiry. The primary HUD pill remains 44 pt and only final text reaches insertion.
- Capture start/stream and insertion failures now log once at the owned worker boundary, using allowlisted categories or known Core Audio numeric status. These diagnostics exclude arbitrary error descriptions, transcript/correction contents and clipboard bytes; History and cleanup behavior remain intact.
- Fresh strict `make test`: **176 XCTest cases, two expected opt-in native skips, zero failures; 12 Swift Testing cases, zero failures; 15 Python packaging/helper cases, zero failures**. Seven new regressions include physical listener → production bridge → controller cancellation with gated final inference, pending presses behind cleanup, queued cancellation, cap expiry/stale timers and safe diagnostics. A deliberate pending-state mutation failed four assertions, then passed after restoration.
- Fresh signed Debug and Release builds pass identity/team/designated-requirement, arm64, hardened-runtime, exact audio-input entitlement and bundled resource-byte checks. The only build warning is the already documented AppIntents metadata-extraction skip. No unchanged native inference/benchmark rerun was needed; shared Moonshine ownership and model code are unchanged.
- Scoped final re-review accepted all three fixes with no new Critical/Important breakage. A Minor diagnostic issue remains: cancellation during capture startup can log `capture start: unknown` because the catch checks the consumer task rather than the canceled startup task. This does not affect cancellation/cleanup or log content privacy. Defer a targeted regression/filter correction; interpret that startup-cancellation log cautiously. Direct permission-poll lifecycle regression coverage also remains deferred after review found no current polling defect.
- Evidence: `.superpowers/sdd/2026-09-29-said-implementation/final-fix-report.md`, `final-fix-review.md` and `final-fix-*.log` (ignored). All 30 human smoke rows and actual notarization remain pending.

## Installed app (2026-09-29)

- Reviewed source commit: `77232c8`. `SAID_CONFIGURATION=Release SAID_INSTALL_DEST=/Applications/sAId.app make install` completed successfully; the installed app has not been launched.
- `/Applications/sAId.app` passes strict signature/designated-requirement/team checks, hardened runtime, arm64, exactly the audio-input entitlement and bundled default/notices byte comparisons. Its executable matches the Release product: SHA256 `d39d9991b51adccab8937a207f050a71f3bc34be7a01921d445150dcf47777d5`.
- Installer lock and owned staging directory were removed. No previous app existed, and no other application was replaced. Logs: `final-install.log` and `final-installed-verification.log` in the ignored SDD directory.
- Agent-owned implementation, automated verification, review, installation and task PR work are complete. Live acceptance and a notarized distribution ZIP still require the human actions below.
- Home-Mini test preparation: Scott is at `freeman-hm-mini`. The installed app above is on `itdir-Mac-Studio`; direct SSH to `freeman-hm-mini.local` did not resolve. A 13 MiB signed local-test ZIP is prepared at `/Users/scottfreeman/Downloads/sAId-home-test-2026-09-29.8dCL0U/sAId-signed-local-test.zip` on the Studio. The extracted copy passed signature/resource checks and matches the installed executable. Archive SHA256: `ca7d8da00f2ea6228d90ebfbc9fc6e4ebd656c5d31d37196b547afe9f1cbc727`. This is not a notarized release. After enabling his VPN, Scott was given an SCP pull command because inbound SSH to the Mini timed out. He now reports dictating into this chat from sAId on `freeman-hm-mini` and confirms live HUD words. Clipboard restoration has not been checked, preview latency was not measured, and the app/binary on the home Mini was not independently inspected. Requirements remain Apple Silicon and macOS 15+.

## Current interfaces

`DictationState` is a struct with independent model readiness, phase, HUD message, physical-held/queued intent, monotonic session IDs and timer IDs. See current `Core/` sources; the original enum-only plan sample was defective and has been replaced.

- `PreviewTranscriber.start() async throws -> AsyncThrowingStream<PreviewLine, Error>` returns a fresh stream per utterance.
- `feed(_:) async throws`, `stop() async`.
- `FinalTranscriber.transcribe(_ pcm16k: [Float]) async throws -> String`.
- Preview lines contain aggregated whole-utterance text.
- `finalText` receives already-postprocessed final text, preserving trailing space. Blank detection uses a trimmed copy.
- Effects/events carry session/timer identity. Controller must preserve IDs, drain ordered audio before finalizing, trim cap samples exactly, and display independent HUD messages.
- Queued presses start after insertion completion only while still held; release/cancel withdraws them. The model-readiness state is not proof that in-flight inference has finished.

Audio integration: `AudioCapture(inputDeviceUID:)` conforms to `CaptureSource`; each `start()` returns a fresh ordered `AsyncThrowingStream<[Float], Error>`. `stop()` quiesces production and finishes accepted chunks; the controller must wait for the consumer to drain. Configuration/wake/device loss ends the current stream with an error and next press creates a new backend. UID is fixed per capture instance; changing settings safely replaces the source.

Insertion integration: `@MainActor TextInserter: TextSink` provides `insert(_:) async throws`; configure clipboard paste or direct Unicode. Completion means events posted and cleanup finished, not target acceptance. Calls reject overlap; controller owns queued presses. Record the final text in History on success or failure. `TextInsertionError.userMessage` provides secure-input or History-copy messaging.

Controller integration: `send(action,target:)` is synchronous/nonisolated and belongs directly in the hotkey callback, preserving physical order. Async `configure`, `setEnabled`, `setModelReadiness` and `handle` acknowledge ordered commands. `sendConfiguration(capture:sink:postProcess:)` synchronously enqueues configuration before a subsequent physical press; capture, sink and postprocess are snapshotted per utterance. `states()` gives initial/current snapshots with newest-value buffering. Terminal `shutdown()` awaits actual capture, preview, inference and insertion cleanup; construct a new controller after replacing engine ownership. History values include start timestamp, target bundle ID, source and failure metadata. Main-actor `HUDPanel.update` observes phase and independent message.

## Models and test fixtures

- Eight Moonshine files are cached at `~/Library/Application Support/sAId/models/moonshine/`.
- Catalog variant: `model/medium-streaming-en/quantized_26_08_21` from Moonshine 0.1.5's native catalog.
- Primary CDN returned HTTP403. The exact files were downloaded from the official `moonshine-ai/moonshine-voice-assets` Hugging Face mirror; sizes and published SHA256 hashes were verified. Downloader must handle that fallback for users too.
- All download processes have finished. The unused Qwen files downloaded during this run were removed; no pre-existing model cache was deleted.
- Test fixtures are three LibriSpeech dev-clean recordings under CC BY 4.0, with attribution and source/WAV hashes. IDs: `1272-128104-0000`, `1272-128104-0005`, `1272-128104-0008`; durations 5.855, 9.01 and 5.12 seconds. Original FLAC is decoded to 16 kHz mono PCM16 without content edits. Six Swift preview sessions on one resident model passed. Recorded WER per clip: 0, 0.0556 and 0.1818; compute wall time in the final run ranged from 0.552 to 1.398 seconds per clip.
- Earlier local-only synthetic probes verified native whole-utterance and streaming support. Their recordings will not be published; the public fixtures use clearly redistributable corpus audio instead. Three clips from one speaker test the pipeline, not accuracy on Scott's voice or broad speech quality.
- Ordinary tests remain offline and avoid model downloads. Explicit `SAID_MODEL_TESTS=1` enables cached-model contract tests; absent/incomplete weights skip. Fast feeding prerecorded audio measures computation time, not live latency.

## Build and runtime facts

- Swift 6.3.3 / Xcode 26.6; no Swift compiler warnings. Signed builds emit the documented Apple AppIntents metadata-extraction skip warning.
- Each worktree needs its own `.build`. Symlinking the original cache produced duplicate absolute module paths and compiler crashes; a clean independent build passed.
- xcodegen is installed. Developer ID identity exists for **Scott DL Freeman, team M2TEAF948X**; verify it when configuring packaging.
- SPM alone does not produce the final .app bundle/TCC identity. Task 10 created the Xcodegen project and signed app at `build/Build/Products/Debug/sAId.app` in the active worktree. Bundle checks confirm org.tvw.said, macOS15, arm64, LSUIElement and microphone purpose, Developer ID team M2TEAF948X, hardened runtime, and only audio-input entitlement. No GUI launch was performed.
- Resources use Bundle.main. No app print(), no unchecked Sendable outside native engine adapters, no transcription in tap, converter input never reports endOfStream for temporary absence.
- Borrowed Parakey code requires its MIT notice. Its old clipboard policy is not ours: preserve/restore clipboard with newer-user-change protection.

## Next work

Scott is on the Studio. Version 1.0.3 fixes the selected-microphone lookup and is reviewed, signed and staged as described at the top. PR #15 is open. Install after Scott quits the currently running 1.0.2 app, verify the installed app, then ask him to reopen and dictate using explicit Wireless Mic Rx and Right Control. Preserve user settings. Earlier Secure Input/window/clipboard/latency acceptance remains pending. Merge approval is still pending. Keep the worktree for PR feedback and live acceptance; do not merge, launch the app or perform desktop automation on Scott's behalf. This thread is long: use this handoff and the saved project memory to start a fresh thread for smoke results.

Human testing has started: Scott reports successful live transcription/insertion into this chat on the home Mini, with visible live HUD words. Next, copy a distinctive clipboard sentinel, dictate in **Notes** with Right Option, then paste on a new line to verify the original sentinel returns. Clipboard restoration is explicitly untested. Record results in `docs/SMOKE.md`; full matrix criteria remain pending, including measured preview latency, other target apps, secure-input refusal, focus, device changes, sleep/wake and eight-hour memory residency.

The last profile check found `said-notary` absent. The existing human question about provisioning it has no answer yet; do not treat the preselected signed-local option as a submitted choice. The completed release pipeline can be used after Scott provisions it interactively in his own terminal:

```bash
xcrun notarytool store-credentials said-notary --team-id M2TEAF948X
make release VERSION=1.0.3
```

Do not send credentials through chat or source files. No credentials were read and no additional profiles probed. Signed local builds are ready without notarization; a notarized distribution ZIP has not been created.

Scott uses this Mac through Splashtop. **Never lock the screen or invoke a Computer Use lock workflow.** Agents have performed no microphone capture, TCC request/grant, keyboard/paste/clipboard operation, GUI launch, screen capture or desktop automation. Scott has now run the app himself on the home Mini as recorded above. All test/build/benchmark/install/review subprocesses have completed; there are no idle waiters. The real signed temporary installation and hardened CLI are retained as review artifacts under ignored `build/`.
