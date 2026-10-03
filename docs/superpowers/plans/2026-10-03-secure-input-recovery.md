# Secure input recovery implementation plan

> Execute this focused bug fix inline with the executing-plans and test-driven-development skills, followed by one fresh independent review under requesting-code-review. Existing autonomous execution authorization applies.

**Goal:** Stop a system-wide Secure Event Input flag from misclassifying every ordinary focused text control as a password field; recover on the next insertion without restart.

**Architecture:** Add a bounded, metadata-only Accessibility read of the current focused control. Recognized secure controls always refuse insertion. Confirmed ordinary text controls may accept insertion despite the global flag; unverified controls retain the conservative global guard and receive a distinct message. Read again at every existing pre-delivery check; never cache an allow decision or disable system security.

**Tech stack:** Swift 6 complete concurrency, AppKit/ApplicationServices/Carbon, macOS 15+ arm64. Moonshine remains unchanged at 0.1.5 English mediumStreaming.

**Spec:** docs/superpowers/specs/2026-09-29-said-dictation-design.md, amended by Scott's 2026-10-03 request to fix all fields becoming secure after extended operation. The old blanket IsSecureEventInputEnabled check is the defect; preserve the goal of refusing actual password fields.

## Evidence

TextInserter queries IsSecureEventInputEnabled freshly at every check and does not cache secure state. Apple's installed CarbonEventsCore.h documents that this returns true when *any process* enables it. Apple TN2150 describes background processes leaving it enabled and interfering with others: https://developer.apple.com/library/archive/technotes/tn2150/_index.html. Therefore a global true cannot establish that the focused control is a password field. The specific process causing Scott's machine to enter that state has not been identified. macOS may also suppress the hotkey itself; no app can promise to undo another process's system security state.

## Constraints and review focus

- No GUI launch, real mic/TCC/keyboard/clipboard, global security enable/disable calls, process killing or desktop locking. Use injected external boundaries for tests.
- Never read AXValue, selected text, labels, titles, URLs or password content. Only focused element identity, PID and role/subrole metadata, with short per-object messaging timeouts.
- Treat failed/malformed/unknown metadata and changing focus as unverified. Do not infer that an ancestor container or arbitrary custom subrole is safe. Explicit secure subrole wins regardless of the global flag.
- Preserve clipboard ownership/restoration, cancellation, secure rechecks before every posted event, and no fallback following a security rejection. No unrelated latency/window/model work.
- Test repeated secure → ordinary transitions with the same inserter and global flag held true; test focus changing during clipboard setup and between Unicode chunks; distinguish unreadable focus from an actual password field.
- Check native metadata mapping and API errors through testable decoding, without querying the user's desktop. Bound AX calls so unresponsive apps cannot hang insertion indefinitely.

## Task 1: field-aware insertion guard and delivery

Files: new Sources/sAId/Insert/FocusedInputSecurity.swift; TextInserter.swift; App/AppViewModel.swift for last-check diagnostics; TextInserterTests.swift and FocusedInputSecurityTests.swift; project.yml version 1.0.2/build3; CLAUDE/spec/HANDOFF/SMOKE/README.

Interfaces: FocusedInputSecurity enum (.ordinaryText, .secure, .unverified); native read() -> FocusedInputSecurity; TextInserter injected focusedInput closure alongside existing global secureInput closure. A content-free latest check records global enabled and focused-control classification for Copy diagnostics, without probing the menu's current focus.

- [ ] Add failing insertion regressions using actual TextInserter with fake clipboard/events and injected global/field state. A permanent global true must allow ordinary text after leaving a password field without replacing the inserter.
- [ ] Add minimal enum/injection scaffolding retaining the old global refusal and capture behavioral RED failures; no real AX reads in tests.
- [ ] Implement metadata classifier and bounded native adapter. Query the frontmost application, focused element and role/subrole; verify focused identity and frontmost PID after reads. Allow only recognized text roles with ordinary/absent documented subroles. Failed subrole reads are not absent.
- [ ] Replace boolean-only rejection with the combined check; add separate unverified/global-active failure and safe latest-check diagnostics. Run focused tests.
- [ ] Test malformed/unsupported AX values, known secure vs ordinary/custom roles, global true/false, immediate secure rechecks and repeated recovery. Native reads remain outside hotkey callbacks.
- [ ] Run make test and signed Release build; review once with a fresh reviewer and fix any material findings. No redundant unchanged suites/native model runs.
- [ ] Commit, push task branch, create/attach PR against main stacked on PR13. Preserve worktree and evidence; do not merge or publish a release.
- [ ] Install signed build on Studio only if prior app is not running and installation is safe; create uniquely named signed local-test ZIP and verify extracted signature/resources/binary. Supply transfer instructions for home retest; no launch. Record live recovery as pending until Scott confirms.
