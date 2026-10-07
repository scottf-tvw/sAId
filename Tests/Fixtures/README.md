# Offline speech fixtures

These three recordings and their reference transcripts are excerpts from the **LibriSpeech ASR corpus, dev-clean**, prepared by **Vassil Panayotov with the assistance of Daniel Povey**, from LibriVox audiobooks. LibriSpeech is distributed under the [Creative Commons Attribution 4.0 International license](https://creativecommons.org/licenses/by/4.0/). These fixture assets retain that license; the application's MIT license does not replace it.

- Original corpus, attribution and license: https://openslr.org/12/
- Redistribution source: https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy/tree/5be91486e11a2d616f4ec5db8d3fd248585ac07a
- Subset: `clean/validation`, rows 0, 5 and 8, LibriSpeech IDs `1272-128104-0000`, `1272-128104-0005`, `1272-128104-0008`.
- Retrieved 2026-09-29. FLAC decoded to 16 kHz mono PCM16 WAV with ffmpeg; no trimming, speech synthesis or content edits. Container metadata removed. Reference text copied unchanged from the corpus, with JSON formatting added.
- `source-metadata.json` records SHA256 digests for both the source FLAC and derived WAV and duration in seconds.

These are three utterances from one speaker. They exercise repeated-session transcription and detect pipeline regressions; they do not establish accuracy on Scott's voice, dictation, jargon, noisy rooms or a broad speech corpus. Fast feeding of prerecorded audio measures computation time, not live-preview latency. There is no endorsement of sAId by the corpus authors.
