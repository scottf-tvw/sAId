# sAId

Push-to-talk dictation for Apple Silicon. Hold **Right Option**, speak, release — the text lands at
your cursor in whatever app is in front, and your clipboard is put back the way it was. A small
floating pill shows live words while you hold the key so you always know it's listening.

Everything runs on-device:

- **Final text and live preview:** Moonshine mediumStreaming (via
  [moonshine-swift](https://github.com/moonshine-ai/moonshine-swift)). One resident model serves both
  roles; the preview is shown in the HUD and only the final transcription is pasted.

Requirements: macOS 15 or later, Apple Silicon.

## Status
Skeleton. The design is in `docs/superpowers/specs/2026-09-29-said-dictation-design.md`; the
implementation plan is in `docs/superpowers/plans/`. See `docs/HANDOFF.md` for the current state.

## Build
```bash
swift build && swift test -Xswiftc -strict-concurrency=complete
xcodegen generate && xcodebuild -project sAId.xcodeproj -scheme sAId -configuration Debug build
```

## Permissions
sAId needs Microphone (to hear you), Input Monitoring (to see the hotkey), and Accessibility (to
paste). The first run walks you through all three.

## License
MIT — see `LICENSE`. The hotkey listener and text-insertion logic are adapted from
[Parakey](https://github.com/rcourtman/parakey) by Richard Courtman (MIT) — see `docs/borrowed/`.
