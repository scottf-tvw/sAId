# sAId manual smoke matrix

Run on real hardware after any change to Hotkey, AudioCapture, Inserter, HUD or Permissions.
These are Scott's to verify; an agent reports them as "needs smoke" in the PR, never as done.

Setup: copy something distinctive to the clipboard first (e.g. `CLIPBOARD-SENTINEL-42`).
After each row, paste (⌘V) somewhere harmless and confirm the sentinel is back.

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
| 9 | Cancel | hold ⌥, speak, press Esc, release | nothing pasted; HUD hides |
| 10 | Long utterance | hold ⌥ for ~30 s of speech | live preview keeps up; final text correct; no truncation |
| 11 | Cap | hold ⌥ for > 120 s | HUD warns at the cap and finalizes on its own |
| 12 | Live preview | hold ⌥, speak slowly | words appear in the HUD within ~0.5 s of being spoken |
| 13 | Corrections | say a word in `corrections.json` (e.g. "invintus") | pasted text shows the corrected form |
| 14 | Filler removal | say "um, so, uh, this is a test" | fillers gone; "So, this is a test." |
| 15 | Mic switch | change input device in Settings while idle, dictate | audio from the new device |
| 16 | Device removed mid-utterance | unplug the USB mic while holding ⌥ | HUD error; next press works after re-plug |
| 17 | Sleep/wake | sleep the Mac, wake, dictate | works without relaunch |
| 18 | TCC reset | `tccutil reset ListenEvent org.tvw.said`, press ⌥ | menu glyph amber; checklist reopens; re-grant → works |
| 19 | Models missing | delete the Moonshine model dir, launch | "Loading models…" then re-download; dictation refused until ready |
| 20 | Memory | leave running 8 h, dictate periodically | RSS stable (~2.5 GB), no growth |
