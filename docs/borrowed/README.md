# Borrowed reference code (not compiled)

These files are verbatim regions of **Parakey** (MIT, © 2026 Richard Courtman,
https://github.com/rcourtman/parakey) as it stood when Scott forked it into
hAIvd-Assist (`TVWIT/hAIvd-Assist` @ `5b0f9a7`, 2026-06-02). They are kept here so
the sAId implementer can adapt the *hotkey listener* and *text insertion* logic (and
the small corrections / filler-removal helpers) without digging through a 9k-line file.

Rules:
- They are **reference**, excluded from the build. Port what you need into `Sources/sAId/`.
- Any file that carries ported code keeps the MIT notice line from the header.
- `parakey-audio-capture-REFERENCE-INVARIANTS.swift` is included ONLY for its two
  invariants (converter input block returns `.noDataNow`; capture runs off the main
  actor). sAId's `AudioCapture` is written fresh — do not port this file wholesale.
