# sAId manual smoke matrix

Run on real hardware after any change to Hotkey, AudioCapture, Inserter, HUD or Permissions.
These are Scott's to verify; an agent reports them as "needs smoke" in the PR, never as done.

## Reported results (2026-09-29)

Scott reports using sAId on `freeman-hm-mini` to dictate a message into this chat, and confirms live words appeared in the HUD. This confirms the basic live transcription/insertion path and visible preview by human report. Preview latency, exact insertion count and the clipboard were not measured or checked; no result is inferred for other targets, secure input, device recovery or the extended soak.

Scott subsequently reports slow text after release and undersized Settings/utility windows. Follow-up **1.0.1 (build 2)** fixes reproduced hosting-size collapse and adds content-free stage timing; home latency remains unresolved.

After replacing the old app while it is quit, open Settings and inspect General, Corrections, Text and Model. Open History (empty/populated as applicable) and Permissions. Confirm useful initial sizes, controls reachable at minimum size, scrolling where content grows, and resizing larger. These checks still need Scott's live acceptance; offscreen geometry checks passed without presenting windows.

Dictate one short utterance and choose **Copy diagnostics** immediately after insertion. Confirm the first line identifies **sAId 1.0.1**, then share the stage timing with the approximate delay you saw. Release mailbox, capture drain, preview drain/stop, final inference, processing and insertion completion identify where time was spent. Preview stop is nested within preview drain; do not add both. Insertion timing includes cleanup and is not a target acceptance receipt. Fixture timings on the Studio do not establish Mini performance. The report contains durations/categories rather than transcript/error/clipboard contents; copying diagnostics deliberately replaces the clipboard, so do the sentinel restoration test separately.

Next first-milestone check (**clipboard not yet checked**): with sAId ready on the home Mini, copy
`CLIPBOARD-SENTINEL-42`, place the cursor in **Notes**, hold **Right Option**, speak, and release.
Confirm live words in the HUD, exactly one final insertion, and restoration of the sentinel when
pasted elsewhere. Record this result before working through the remaining matrix. Signed fixture
inference does not verify GUI focus, microphone/input permissions, or actual paste delivery.

Setup: copy something distinctive to the clipboard first (e.g. `CLIPBOARD-SENTINEL-42`).
After each row, paste (⌘V) somewhere harmless and confirm the sentinel is back. The report above partially covers live preview; the full row criteria below remain **needs smoke** until Scott records each result; automated tests do not satisfy them. Scott controls sleep, permissions and real app input; the agent must not lock the Mac or run these actions through desktop automation.

| # | Target | Steps | Pass when |
|---|---|---|---|
| 1 | Terminal | hold ⌥, "echo hello world", release | text typed at the prompt; clipboard restored |
| 2 | Safari text field (e.g. a search box) | same | text in the field; page not navigated; clipboard restored |
| 3 | Slack message box | same | text in the box, not sent; clipboard restored |
| 4 | Mail compose body | same | text at the cursor; clipboard restored |
| 5 | VS Code editor | same | text at the caret; no command palette triggered |
| 6 | Notes | same | text at the caret |
| 7 | Password field (Safari login or System Settings) | hold ⌥, speak | **refused**: HUD says "Secure input field"; nothing pasted; transcript in History |
| 8 | Tap, don't hold (< 250 ms) | tap ⌥ | nothing happens; no HUD flash beyond a blink |
| 9 | Cancel | test Esc while holding and again after release while finalization is pending; also test idle Esc | pending text is not pasted; HUD hides; idle Esc reaches the target (already-posted events cannot be retracted) |
| 10 | Long utterance | hold ⌥ for ~30 s of speech | live preview keeps up; final text correct; no truncation |
| 11 | Cap | hold ⌥ for > 120 s | HUD warns at the cap and finalizes on its own |
| 12 | Live preview | hold ⌥, speak slowly | words appear in the HUD within ~0.5 s of being spoken |
| 13 | Corrections | say a word in `corrections.json` (e.g. "invintus") | pasted text shows the corrected form |
| 14 | Filler removal | say "um, so, uh, this is a test" | configured fillers gone; remaining words preserved |
| 15 | Mic switch | change input device in Settings while idle, dictate | audio from the new device |
| 16 | Device removed mid-utterance | unplug the USB mic while holding ⌥ | HUD error; next press works after re-plug |
| 17 | Sleep/wake | sleep the Mac, wake, dictate | works without relaunch |
| 18 | TCC reset | `tccutil reset ListenEvent org.tvw.said`, press ⌥ | menu glyph amber; checklist reopens; re-grant → works |
| 19 | Model reset/retry | use Settings → Models → Reset, confirm the app-owned cache reset, then retry | progress shown during download/load; dictation refused until ready; unrelated files untouched |
| 20 | Memory | record RSS after model load and a few warm-up utterances; leave running 8 h and dictate periodically | one resident model; footprint settles near the measured baseline without sustained growth; record actual values |
| 21 | Both Option keys | hold Left Option, press and hold Right Option, release only Right Option | dictation finalizes even while Left Option stays held; next press works |
| 22 | Cancel/repeat | start, Esc, release Right Option, then start another utterance | canceled text is not pasted; subsequent live preview and final insertion work |
| 23 | Queued press | press Right Option again while prior transcript finalizes; test held and early-released variants | held press starts after prior insertion completes; an already released press does not start capture |
| 24 | Newer clipboard content | copy something new while dictation is restoring its temporary clipboard text | newer clipboard content survives; older sentinel is not restored over it |
| 25 | Unicode strategy | select direct Unicode insertion and dictate into an app that ignores paste | one copy of the final text appears; emoji/accented text survives; clipboard stays intact |
| 26 | Offline launch | with a complete model cache, disconnect networking and relaunch | model becomes ready and preview/final dictation work without a download |
| 27 | Dictation toggle | turn dictation off during capture, release, then re-enable and dictate | active capture stops without pasting; hotkey is gated while off; next session works |
| 28 | Settings persistence | edit/import/export corrections, empty the list intentionally, adjust fillers/trailing space, relaunch | choices persist and affect subsequent utterances; an empty list stays empty; export/import round trip works |
| 29 | History recovery | trigger a secure-input refusal, open History, copy the failed transcript, then clear History | final text and correct target app are present; Copy works; all History views agree after Clear |
| 30 | HUD focus | dictate with the cursor in a target field and pointer on a different display | HUD appears on the pointer's screen, never takes focus or intercepts clicks, and fades after completion |
