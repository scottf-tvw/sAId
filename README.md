# sAId

Push-to-talk dictation for Apple Silicon. Hold **Right Option**, speak, release — final text is
inserted at the cursor. A floating HUD shows live words while you hold. Clipboard paste restores
the original contents unless you have copied something newer; direct Unicode insertion is also
selectable.

Everything runs on-device. One resident English **Moonshine mediumStreaming** model supplies both
preview and final transcription through [moonshine-swift](https://github.com/moonshine-ai/moonshine-swift),
pinned to **0.1.5**. Preview text is display-only; only the completed final pass is inserted.

Requires macOS 15 or later and Apple Silicon.

## Status

The standalone menu-bar app, settings, History, permission recovery, benchmark, and packaging
pipeline are implemented. Signed Debug/Release bundles and cached native inference have been
verified. Scott reports live preview and transcription inserted into this chat from his home Mini.
Full hardware acceptance remains pending: clipboard restoration, other target apps, HUD focus,
permission recovery and the eight-hour residency test still need the checks in [SMOKE.md](docs/SMOKE.md).
Automated tests do not establish those results.

The latest update is on `codex/fix-secure-input-recovery`; [PR #14](https://github.com/scottf-tvw/sAId/pull/14)
fixes ordinary fields being rejected when another process leaves macOS Secure Input enabled. Focused
control metadata is checked before delivery; password fields still refuse, and unknown controls remain
blocked while global Secure Input is active. Review findings around cancellation and clipboard changes
during the check were fixed with regression coverage. Copy diagnostics records the last security decision.

Signed Release 1.0.2 (build 3) is installed on the implementation Mac without an agent launch; a verified
signed local-test ZIP is ready for the home recovery check. PRs #1–14 remain open and unmerged pending approval.
The earlier utility-window fix is included; home insertion latency still needs measurements. Transfer
instructions, remaining checks and verification are in [HANDOFF.md](docs/HANDOFF.md).

## Build and install

Development requires Xcode with its command-line tools, Swift 6.1+, XcodeGen, and Python 3 for the
packaging tests. Shell scripts support macOS Bash 3.2. The first build resolves the pinned public
Moonshine binary dependency. App builds require an available Developer ID Application identity;
this repository defaults to Scott DL Freeman, team `M2TEAF948X`.

```bash
make build                       # strict SPM compilation
make test                        # offline unit tests plus stubbed packaging failure tests
make app                         # signed Debug .app in build/Build/Products/Debug/
SAID_CONFIGURATION=Release make app
make install                     # builds Release, verifies, safely stages/swaps /Applications/sAId.app
```

Installation does not launch the app, invoke sudo, or grant permissions. It preserves the previous
app through build/staging/verification and restores it on a failed swap when the destination remains
free. Install, rollback and ZIP publication use macOS atomic exclusive renames: an appearing destination
is never overwritten or treated as a containing directory. If rollback is blocked, the prior app stays
in the reported recovery directory and the competing destination is left intact. Installers serialize
with a `.sAId-install.lock` directory beside the app; an existing lock fails clearly instead of waiting.
After a forcibly killed installer, confirm it is no longer running and recover any retained app before
removing its stale lock. Launch the installed app explicitly
when ready. An owned test destination may be supplied with `SAID_INSTALL_DEST=/absolute/path/sAId.app`;
its parent directory must already exist and be writable. `SAID_BUILD_DIR` selects the build directory.
For another signing account, set `SAID_SIGNING_IDENTITY` and `SAID_TEAM_ID` to a matching Developer ID.

SPM's `sAId` executable is a compile/test product; use the Xcode-built `.app` for the menu bar and
stable TCC identity. `SaidEngine` is shared by that app and `said-bench`; the CLI does not contain a
second inference implementation.

## Permissions and first dictation

Launch the installed app, then use its checklist to grant **Microphone**, **Input Monitoring**, and
**Accessibility**. Wait for Models ready. In Notes, copy `CLIPBOARD-SENTINEL-42`, place the cursor in a
note, hold Right Option and speak, then release. Confirm live HUD words, one final insertion, and the
sentinel restored when pasted elsewhere. Record the result in [SMOKE.md](docs/SMOKE.md); all manual
rows are currently pending. Keep the Mac accessible through Splashtop; do not run lock-screen automation.

Model files live in `~/Library/Application Support/sAId/models/moonshine/`. The app downloads missing
files from the public Moonshine catalog with verified official-mirror fallback; a complete cache
works offline. Settings and History are stored in the same app's Application Support directory.
The model remains resident until quit or an explicit, confirmed idle reset.

## Offline benchmark

```bash
# Both roles, one cached resident model for all files; no model downloads:
./scripts/bench.sh --preview Tests/Fixtures Tests/Fixtures/transcripts.json
# Offline native integration contracts (skip if the verified cache is missing):
SAID_MODEL_TESTS=1 swift test --filter 'MoonshineModelContractTests|MoonshineFinalEngineTests'
```

The CLI accepts uncompressed **16 kHz mono PCM16 WAV** files and a JSON object mapping each filename
to its unchanged reference text. It rejects malformed/truncated audio and exits nonzero on input or
model failure. `--model-root PATH` selects another existing cache; omit `--preview` for the final path
alone. Inputs are validated before the single model load.

WER uses lowercase alphanumeric token sequences and Levenshtein edits; punctuation separates words.
Numbers are not expanded or rewritten. Each file reports edits, reference word count, WER and compute
seconds. Corpus WER divides summed edits by summed reference words, rather than averaging file WERs.
An empty reference with empty output has WER 0; nonempty output has undefined WER, while its insertions
still contribute to the corpus numerator. An all-empty-reference corpus follows that same rule.

For Scott's optional 20-sentence jargon corpus, record one sentence per WAV in the required format,
including broadcast/IT terms and legislative names, and write the literal reference text before
running recognition. For example, `{"01.wav":"The original sentence.","02.wav":"Another sentence."}`.
Keep personal recordings outside the public repository. Run the same command against that directory
and JSON file. Do not rewrite references to match recognized substitutions.

The bundled three LibriSpeech clips are one-speaker pipeline fixtures, not a measurement of Scott's
accuracy. Measurements and limitations are recorded in [HANDOFF.md](docs/HANDOFF.md). Fast feeding of
prerecorded clips measures compute time, **not live preview or release-to-paste latency**.

## Release

```bash
make release VERSION=1.0.2
```

The script sets the bundle version, builds Release, stages and signs it with Developer ID and hardened
runtime, verifies signature/resources/entitlements, submits via the `said-notary` Keychain profile,
requires Accepted status, staples and validates, then creates `dist/sAId-VERSION.zip`. Existing release
ZIPs are never overwritten, including when another process publishes during the final operation.
The small exclusive-rename helper is compiled with the selected Xcode SDK into owned staging; unsupported
filesystem operations fail closed. Failed notarization leaves no final named release ZIP. Nothing is published
to GitHub. `SAID_DIST_DIR` and `SAID_NOTARY_PROFILE` are optional overrides.

The `said-notary` profile is not provisioned on the implementation Mac; actual notarization is pending.
Scott can provision it interactively in his terminal (supply credentials there, never in chat or source):

```bash
xcrun notarytool store-credentials said-notary --team-id M2TEAF948X
```

## License

sAId is MIT — see [LICENSE](LICENSE). Adapted Parakey hotkey, insertion and text helpers retain their MIT
attribution in source and [docs/borrowed](docs/borrowed/). The app ships its license, Parakey's license,
NOTICE, and the pinned full Moonshine upstream license/third-party notices in `Contents/Resources`.
Bundled test recordings are separately CC BY 4.0; provenance is in [Tests/Fixtures/README.md](Tests/Fixtures/README.md).
Those test recordings are not shipped in the app.
