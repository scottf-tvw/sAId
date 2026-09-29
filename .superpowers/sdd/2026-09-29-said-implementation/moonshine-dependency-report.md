# Moonshine dependency amendment

Base: `c712ad9b5315940fc30576bae6245c75e6ff2354`
Amendment head: `ae80b1147e88c8bd91114d272757edf915c7d52d`

The app now pins `moonshine-swift` exactly to 0.1.5 and removes `speech-swift`, Qwen3-ASR, and their MLX dependency tree. README and CLAUDE describe one resident Moonshine mediumStreaming model serving preview and final transcription. Preview text remains display-only. No third-party license notice was needed in `NOTICE`; it continues to cover the Parakey-derived code.

Verification:

- `swift package resolve` — passed; `Package.resolved` contains only `moonshine-swift` 0.1.5.
- `swift package show-dependencies` — passed; dependency tree contains only `moonshine-swift` 0.1.5.
- `swift build` — passed.
- `swift test -Xswiftc -strict-concurrency=complete` — passed, 42 tests, 0 failures.
- `git diff --check` — passed.

This change updates package selection and project guidance. The Moonshine final and preview adapters are planned for later implementation tasks.
