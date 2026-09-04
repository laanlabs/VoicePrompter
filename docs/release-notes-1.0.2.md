# VoicePrompter 1.0.2 (Build 2)

## App Store “What’s New”

VoiceTrack speech setup is now much more reliable. This update uses a smaller model suited to your device, repairs incomplete downloads, shows clearer setup progress, and makes retrying or canceling straightforward. It also fixes cases where VoiceTrack could remain stuck after setup or continue starting after you left the screen.

## Release summary

- Replaces the oversized `small.en` model with device-appropriate `base.en` or `tiny.en` files (~150–160 MB).
- Verifies downloaded Core ML files and tokenizer readiness before accepting cached setup.
- Repairs corrupt or interrupted downloads instead of reusing rejected cache metadata.
- Coalesces concurrent starts and cancels model/audio startup on stop or dismissal.
- Surfaces offline, low-storage, initialization, microphone-permission, and audio-start failures with retry and cancel actions.
- Uses real byte progress during download and an indeterminate state during Core ML preparation.
- Pins WhisperKit to the tested immutable revision.

## Validation

- Release build and static analysis: passed.
- Deterministic regression suite: 12 passed, 0 failed (plus one disabled live-network test).
- Live `base.en` download, verification, prewarm, tokenizer load, and model load: passed in the iOS simulator.
- Signed archive, store bundle validation, and App Store Connect IPA export: passed.

The original customer's exact termination reason still requires their crash or Jetsam report. Run a final cold/cached VoiceTrack smoke test on the oldest supported physical device before phased release.
