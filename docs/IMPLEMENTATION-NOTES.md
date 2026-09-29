# Implementation notes

The design is the authority when an implementation-plan code sample disagrees with it.

## Decisions made during implementation

- Scott changed the engine selection during implementation: Moonshine supplies both live preview
  and final transcription. Use one resident `mediumStreaming` model with serialized native access;
  final text is produced after release and then postprocessed before insertion. Remove Qwen and
  its dependency tree. This supersedes the original dual-engine decision.

- Keep model readiness separate from transient HUD messages, so dismissing a loading error cannot enable dictation before the final engine is ready.
- Represent insertion explicitly and retain the final text. Preview text is only eligible for History when final transcription fails.
- Queue a new press during finalization/insertion only while that key remains held. Releasing or canceling it withdraws the pending request; capture never overlaps insertion.
- Tag asynchronous session work and timers so late results cannot affect another utterance.
- Preserve audio ordering and drain captured chunks before final inference. Preview failures must not discard final-engine audio.
- Use checked Swift concurrency outside the shared third-party engine adapter. Plan examples using `@unchecked Sendable` for capture, hotkey, history, or fakes need replacement.
- Rebuild audio capture after a device configuration change or wake. These paths require the real-hardware smoke tests even when lifecycle unit tests pass.
- Restore the previous clipboard on success, failure, and cancellation. If the user copies something new meanwhile, preserve their newer clipboard content.
- A posted keyboard event has no universal receipt from the target app. Offer a selectable direct-Unicode insertion strategy for apps that ignore paste, and automatic fallback only for failures known to precede event delivery. Never claim that event creation proves a target field accepted text.
- Keep numbers, URLs, identifiers, and correction replacement casing protected across the whole post-processing pipeline.
- Keep model contract tests explicitly opt-in and offline. Missing weights cause a skip; ordinary unit tests must not download models or access the microphone.

## Build environment

- Active implementation uses a Codex-managed worktree, leaving the original checkout on `main`.
- Use an independent `.build` cache for each checkout. Symlinking an existing cache caused duplicate absolute module paths and compiler crashes; a clean independent build passed.
- Developer ID signing identity is available for team `M2TEAF948X`; verify its availability when configuring packaging.
- This application is native Apple Silicon. No container deployment is involved.

## Verification still requiring Scott

Permission grants, real microphone capture, paste delivery and clipboard restoration across real target applications, secure-input refusal, device switching/removal, sleep/wake, and the extended memory soak are tracked in [SMOKE.md](SMOKE.md). Automated checks do not mark those rows passed.

Do not lock the screen or invoke desktop automation that acquires the Computer Use lock; Scott uses this Mac through Splashtop.
