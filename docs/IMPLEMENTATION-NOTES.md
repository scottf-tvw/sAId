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
- Preserve audio ordering and drain captured chunks before final inference and before deciding whether a release was a short tap. Queued samples count toward the actual audio duration. Preview failures must not discard final-engine audio.
- A preview error emitted during stop must still be logged even after the reducer has entered finalization; it must not disable the final path or affect a later session.
- Use checked Swift concurrency outside the shared third-party engine adapter. Plan examples using `@unchecked Sendable` for capture, hotkey, history, or fakes need replacement.
- Rebuild audio capture after a device configuration change or wake. These paths require the real-hardware smoke tests even when lifecycle unit tests pass.
- Restore the previous clipboard on success, failure, and cancellation. If the user copies something new meanwhile, preserve their newer clipboard content.
- A posted keyboard event has no universal receipt from the target app. Offer a selectable direct-Unicode insertion strategy for apps that ignore paste, and automatic fallback only for failures known to precede event delivery. Never claim that event creation proves a target field accepted text.
- Keep numbers, URLs, identifiers, and correction replacement casing protected across the whole post-processing pipeline.
- Publish only fixtures with clear redistribution rights: three CC BY 4.0 LibriSpeech clips with attribution, source IDs and hashes. Earlier Apple System Voice recordings stay local and are not repository fixtures.
- Keep model contract tests explicitly opt-in and offline. Missing weights cause a skip; ordinary unit tests must not download models or access the microphone.

## Integration rulings and tradeoffs

These decisions resolve gaps or contradictions in the original implementation samples. The approved design and Scott's later instructions remain authoritative.

| Decision | Reason | Cost or limitation |
|---|---|---|
| Follow the specification when plan samples disagree. | Some samples violated their own concurrency and state requirements. | Interface changes must be carried into dependent modules. |
| Restore the clipboard after failure and cancellation too. | The clipboard-preservation requirement applies to every exit. | A failed insertion is recovered through History/Copy. |
| Treat posted input as posting, not proof of acceptance. | macOS keyboard events have no universal target-app receipt. | Apps that ignore paste may require the selectable Unicode strategy. |
| Surface preview errors through a throwing stream, including stop-time errors. | A separate error channel would complicate ordering and ownership. | Consumers must drain and handle stream termination correctly. |
| Apply device changes through source replacement; retain each session's settings. | Active capture must stop and drain without orphaning its source. | A device change cancels active listening; already captured final/insertion work can finish. |
| Mark app-generated keyboard events and bypass hotkey suppression for them. | A configurable hotkey can otherwise swallow the app's own insertion events. | The event-origin filter must stay consistent across both input paths. |
| Publish attributed LibriSpeech fixtures instead of local Apple voice recordings. | The corpus has explicit redistribution terms. | Three clips from one speaker verify the pipeline, not Scott's vocabulary or broad accuracy. |
| Allow cancellation during finalization/insertion while awaiting actual cleanup. | An idle visual state does not prove native work or clipboard ownership has ended. | Cancellation cannot retract keyboard events that have already been posted. |
| Separate visible permission-checklist polling from a five-second enabled-state health check. | Revoked Input Monitoring can suppress the very callback that would detect its loss. | A small periodic permission read remains while dictation is enabled; real OS behavior needs smoke testing. |
| Keep the primary HUD at 44 pt and place independent notices above it. | Errors can coexist with an active capture state. | A notice temporarily increases the total overlay height. |
| Explicitly release native model ownership before confirmed cache reset/reload. | Retained controller/task references can keep an old engine alive after shutdown. | Reset is quiescent and idle-only; it is not an idle-unload feature. |
| Defer additional injected permission-poll lifecycle tests after review found current behavior correct. | This was a nonblocking coverage suggestion, not a current defect. | Future changes to polling should add focused regressions; Scott's permission-loss smoke remains pending. |

Settings also enter the controller mailbox synchronously, and each utterance retains its insertion sink and postprocessing snapshot. The hotkey bridge sends an ordered release after cancellation because the listener may omit a later release callback for that canceled hold. Regression tests exercise these production boundaries.

## Build environment

- Active implementation uses a Codex-managed worktree, leaving the original checkout on `main`.
- Use an independent `.build` cache for each checkout. Symlinking an existing cache caused duplicate absolute module paths and compiler crashes; a clean independent build passed.
- Developer ID signing identity is available for team `M2TEAF948X`; verify its availability when configuring packaging.
- This application is native Apple Silicon. No container deployment is involved.

## Verification still requiring Scott

Permission grants, real microphone capture, paste delivery and clipboard restoration across real target applications, secure-input refusal, device switching/removal, sleep/wake, and the extended memory soak are tracked in [SMOKE.md](SMOKE.md). Automated checks do not mark those rows passed.

Do not lock the screen or invoke desktop automation that acquires the Computer Use lock; Scott uses this Mac through Splashtop.
