# Home Mac smoke fixes implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to carry this focused follow-up through implementation and one independent review. The existing isolated worktree and autonomous execution authorization remain in force.

**Goal:** Make Settings, History and Permissions open at useful content sizes, and identify/measure the delay between releasing the dictation key and inserting final text on Scott's home Mini.

**Architecture:** Keep the existing AppKit windows hosting SwiftUI views and the single resident Moonshine engine. Investigate window hosting/layout and the ordered release pipeline before changing either. Preserve final-only insertion and cleanup ownership; add safe stage timing visible through Copy diagnostics when local evidence cannot establish the home machine's delay.

**Tech Stack:** Swift 6 complete concurrency; AppKit/SwiftUI; MoonshineVoice 0.1.5; XCTest/Swift Testing; signed arm64 Release app.

**Spec:** docs/superpowers/specs/2026-09-29-said-dictation-design.md plus Scott's new reports: text appears slowly after release, and properties/settings windows open too small for their contents.

## Global constraints

- Preserve one resident English mediumStreaming model for streaming preview and the whole-utterance final pass; no new LLM, idle unloading, or speculative switch to pasting preview.
- Preserve audio drain/order/exact caps, synchronous physical command intake, cancellation and queued-session behavior, clipboard ownership/newer-copy protection, and secure-input refusal.
- Never lock the Mac, launch sAId, show/activate test windows, access the real microphone/TCC/clipboard or inject actual keyboard input. Offscreen AppKit layout probes without activation are allowed. Scott owns live acceptance.
- Do not log or include transcript, corrections, clipboard bytes, arbitrary errors, or machine/network identifiers in timing diagnostics. Monotonic stage durations and outcome categories suffice.
- Reuse the current worktree on fix/home-smoke-latency-windows, based on e49a33e. No merge or release publication; no new unrelated refactor or deferred-minor cleanup.
- Only add tests that catch real behavioral regressions. The reversible window sizing adjustment needs a concrete layout reproduction/verification, not assertions mirroring size constants. Timing/ordering changes require focused regressions and full suite validation.
- No subagents spawned by the implementer. All work processes must end and be accounted for; no idle watchers. Do not repeat unchanged suites after a passing final run.

## Review focus

1. SwiftUI ideal-size propagation must not collapse initial/restored windows or make controls unreachable. Check Settings tabs, empty/populated History and permission text.
2. Required content sizing must fit available screen space and preserve scrolling/resizing where content can grow; avoid an oversized unresizable window.
3. Distinguish physical release, mailbox wait, capture drain, preview drain, final inference, text processing and insertion completion in any reported timings. Never label clipboard cleanup completion as proof of target acceptance.
4. Canceled, failed, capped, short-tap and queued sessions must not mix another session's timings or delay/corrupt cleanup.
5. Do not assert a home-Mini performance improvement based solely on a different machine's synthetic/native fixture measurements.

### Task 1: Diagnose and implement the focused follow-up

**Files:** App/AppDelegate.swift and relevant UI views for window sizing; Core/DictationController.swift and a small Core timing value/recorder if needed; App/AppViewModel.swift/Support diagnostics for Copy diagnostics; relevant existing/new controller tests; docs/HANDOFF.md and docs/SMOKE.md. Engine/benchmark files only if investigation proves a concrete need.

**Interfaces:** Keep existing PreviewTranscriber/FinalTranscriber and capture/sink contracts unless evidence establishes a necessary narrow amendment. Reuse AppViewModel.copyDiagnostics as the human-readable safe diagnostic entry point. Preserve standard window titles and lifecycle callbacks, especially checklistVisibility on open/close.

- [x] Reproduce the window issue with an offscreen AppKit/SwiftUI probe, inspecting content size before/after NSHostingController attachment/layout. Investigate sizingOptions, contentMinSize vs outer minSize, and the actual views' minimum/scrolling needs. No real app/window activation.
- [x] Apply the smallest verified sizing correction. Settings currently requests660x640, History640x500, Permissions550x360; these are current baselines, not sufficient proof of fit. Set content sizing after hosting attachment and constrain useful content size while respecting smaller screens and growth. Verify the corrected production path offscreen.
- [x] Trace release through controller intake, capture stop, preview queue/stop, full final inference, postprocess and insertion. Native Stream.stop forces a trailing transcription; do not skip it or replace the final path without measured evidence and preserving errors/ownership. The150ms clipboard-restore wait is after posting, not an explanation for pre-insertion latency.
- [x] Measure stages using existing attributed fixtures and the real shared engine in an owned scratch probe when helpful. Use paced feeding if comparing release-tail delay; fast-feed totals are not release latency. Never record real audio. Describe exactly what the measurements do and do not prove.
- [x] If the home delay cannot be reproduced/attributed locally, implement compact, content-free per-session stage timing surfaced by Copy diagnostics. Write focused regression tests first for timing/session attribution, cancellation/failure and ordering, then minimal implementation. Use a monotonic injectable clock; avoid sleeps in deterministic unit tests and do not add extra per-key tasks.
- [x] Fix any latency defect only when the measured evidence identifies its root cause. Otherwise deliver the sizing correction plus actionable diagnostics and clearly request one home-Mini timing capture. Do not claim latency fixed while it is unresolved.
- [x] Run meaningful focused checks, then `make test` once on final code and `SAID_CONFIGURATION=Release make app`; verify signature/resources through existing scripts. Run native fixture checks only if native behavior changes or to answer a specific new latency question.
- [x] Update truthful HANDOFF/SMOKE with root cause, changes, evidence, and exact remaining home test. Write an ignored report with commands/raw-log paths, commit changes on this branch and report completion. No install, ZIP transfer, push or PR: parent handles reviewed delivery.

## Parent delivery

Read the report/raw evidence, perform one independent whole-change review (fix/re-review only if needed), then install the reviewed Release on the Studio without launching it and create a fresh uniquely named signed local-test ZIP. Push this branch and open/attach its PR against main, stacked on PR12. Give Scott a new SCP pull command, ask him to quit the old app before replacing it, then retest windows and one short utterance and use Copy diagnostics for measured stage timing. Notarization/merge authorization remain separately pending.

Delivery completed 2026-09-29: implementation dbc2577 and wording fix b9f9a68 accepted by independent review; signed Release 1.0.1 build 2 installed and verified on the Studio without launch. A verified signed local-test ZIP is ready; PR #13 is open/attached against main, stacked on PR #12. HANDOFF records the SCP command and exact artifact hashes. Home window acceptance and measured latency remain pending; no latency improvement is claimed. Worktree/evidence retained, no merge or notarization.
