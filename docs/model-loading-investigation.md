# VoicePrompter model-loading complaint investigation

Investigated September 3, 2026 against commit `284199af094fd7e268fd6f15118818bd6bcea8aa`. The project declares version 1.0.1, build 1; Xcode's local App Store product metadata also contains that version. No matching archive was available to verify that the shipped binary used exactly this source and dependency lockfile.

## Remediation status — September 4, 2026

The findings below were corrected for version 1.0.2, build 2. The app now selects `base.en` normally and `tiny.en` on devices with no more than 3 GB of physical memory, verifies every downloaded model file with a SHA-256 receipt, rejects incomplete model/tokenizer caches, removes rejected files and their Hugging Face metadata before retrying, and migrates away from the legacy `small.en` download. Download storage is excluded from backup.

Model setup and microphone startup now share one cancelable task. Concurrent starts are coalesced, stop/dismissal prevents late audio startup, and model, network, storage, and microphone failures all reach a recoverable UI with retry/cancel actions. Download percentages come from the downloader; Core ML preparation uses an indeterminate indicator. WhisperKit is pinned to immutable revision `9c673e35193fe4e67593dd2973c157ebe666e598`.

Validation completed on September 4:

- 12 deterministic model-cache/startup tests passed; the opt-in live test is skipped during routine runs.
- A separate live integration test downloaded the real `base.en` snapshot, verified it, prewarmed and loaded Core ML and the tokenizer, and reached ready state in the iOS simulator.
- Release build, Xcode static analysis, signed archive, store bundle validation, and App Store Connect IPA export all succeeded.

The exact cause of the original process exit remains unconfirmed without the customer's crash or Jetsam report. Before rollout, run the exported build on the oldest supported physical device to measure peak memory during both cold and cached setup.

The complaint describes the first-use speech-model download, followed on subsequent attempts by a cache-loading message and a failure. The demo uses the same VoiceTrack startup path as other scripts.

**Assessment:** if “died” means the app closed, excessive memory use or a native Core ML failure during model initialization is the leading hypothesis, especially on older devices. If it means the screen stayed stuck, there is a confirmed audio-error path that leaves the loading overlay visible indefinitely. The complaint alone does not establish which happened. No matching VoicePrompter crash or termination report was found in the local Xcode product, device-log, or DiagnosticReports locations checked.

## Findings

1. **The selected model is much larger than the advertised download and bypasses device recommendations.** `WhisperService.swift:25` hardcodes `openai_whisper-small.en`; line 140 promises approximately 150 MB. The publisher lists [small.en at 487 MB](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small.en), while [base.en is 147 MB](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-base.en). The [App Store description](https://apps.apple.com/us/app/voiceprompter-ai-teleprompter/id6756851576) also promises 150 MB and supports iOS 17+. These are model-file sizes, not measured runtime memory. The pinned WhisperKit dependency's support table recommends tiny for A12/A13 devices and lists only tiny/base variants as supported on them; the [publisher's current support table](https://huggingface.co/argmaxinc/whisperkit-coreml/blob/main/config.json) agrees. Passing an explicit model skips WhisperKit's device-based default selection. This is a confirmed configuration problem; an actual memory termination is still unconfirmed.

2. **“Cached” does not mean ready to run.** `WhisperService.swift:49–71` counts immediate non-hidden directory entries and accepts five as complete. It never checks model contents, sizes, integrity, or the separate tokenizer cache. An executable check confirmed that three empty `.mlmodelc` directories plus two empty JSON objects satisfy this check. The cached branch then calls `WhisperKit(... prewarm: true, load: true, download: false)` at line 165. Device specialization, loading model weights, and tokenizer initialization still occur. The pinned dependency can fetch a missing tokenizer even when model downloading is disabled. A first run interrupted after the model download can therefore show “cached” on the next run while setup remains incomplete.

3. **The “fresh copy” recovery can reuse the rejected files.** The catch at `WhisperService.swift:176–181` calls `downloadModel()` without invalidating any model files or Hugging Face metadata. The pinned `swift-transformers` downloader returns an existing file without rehashing it when its stored commit or ETag matches the remote metadata. Missing files can be repaired, but an existing corrupt file with matching metadata can be returned again. Also, every cached-load error is treated as a reason to redownload, including errors unrelated to file corruption.

4. **Progress and preparation messages are timer-driven.** `WhisperService.swift:74–129` invents cache-load stages; lines 269–283 advance download progress independently of bytes received. The download initializer also performs prewarming/loading before returning, so the screen can still say “Downloading” while Core ML is initializing. Neither the percentage nor messages such as “Preparing decoder” identify the actual failing operation.

5. **An audio-start error leaves the loading overlay stuck.** `VoiceTrackEngine.swift:100–118` sets `.loadingModel`, loads the model, then calls `audioCapture.start()`. If that throws, state remains `.loadingModel`. `TeleprompterView.swift:386–389` only prints the error; its error display observes WhisperService, which has no error in this case. Injecting an audio-start failure reproduced state `.loadingModel`, a successfully loaded model, and a nil model error. This explains a stuck screen, not an established process crash.

6. **Startup is neither coalesced nor canceled when stopped.** `loadModel()` checks only `isModelLoaded`, and `VoiceTrackEngine.start()` checks only `isRunning`, both set after awaited work. Two concurrent calls produced two overlapping model initializations in the harness. `stop()` immediately returns during loading because `isRunning` is still false. A second check called `stop()` during loading and observed audio starting afterward. `TeleprompterView` creates an untracked Task for startup and calls `stop()` on disappearance. These defects can prolong work after dismissal and can amplify memory use when starts overlap; overlap during this customer's attempt is not established.

7. **Ordinary connectivity failures may offer no retry.** The error classifier uses localized string matching for a few timeout/server codes. Injecting `URLError(.notConnectedToInternet)` resulted in `canRetry == false`; the loading overlay then hides its “Try Again” button. Low-storage and model initialization errors are also labeled as download failures rather than being distinguished by phase.

## Dependency evidence

The code review used the exact revisions in `Package.resolved`, read from existing local Git objects rather than the unrelated checkout's current HEAD:

- WhisperKit: `9c673e35193fe4e67593dd2973c157ebe666e598`. Relevant files: `Core/WhisperKit.swift` (explicit-model selection, setup sequence, tokenizer loading), `Core/Configurations.swift` (prewarming), `Core/Models.swift` (device support), and `Utilities/ModelUtilities.swift` (tokenizer lookup/download).
- swift-transformers: `573e5c9036c2f136b3a8a071da8e8907322403d0`. Relevant file: `Sources/Hub/HubApi.swift:507–546`, especially the commit/ETag cache fast paths.

Prewarming is already enabled. WhisperKit documents it as reducing peak specialization memory by loading/unloading models sequentially; disabling it is not an appropriate assumed memory fix. Cached source model files and Core ML's device-specialized cache are separate. The latter can be evicted after OS updates or disuse.

The affected build followed WhisperKit's `main` branch, although its checked-in lockfile recorded a specific commit. Version 1.0.2 pins that tested revision directly; the former branch setting was not evidence of this customer's crash.

## Initial validation performed

A temporary Swift harness compiled the production `VoiceTrackEngine`, `TextMatcher`, and `MarkdownParser` directly, plus a copy of `WhisperService` with only its Documents path redirected to a temporary fixture. WhisperKit and microphone hardware were replaced with deterministic test doubles. Five assertions passed:

- Empty model directories are considered a complete cache.
- Concurrent loads create two overlapping model initializations.
- Stopping during loading still allows subsequent audio startup.
- An injected audio-start error leaves the engine in `.loadingModel` without a displayed model error.
- An injected offline error disables retry.

Harness sources and captured output are in `/private/tmp/voiceprompter-investigation-y7ffct_0/`; output is `results.txt`. These initial checks validated application logic, not actual model validity, model memory consumption, hardware audio behavior, or an iOS process termination. At that stage, no full iOS build or physical-device reproduction had been performed and no application source had been changed; the remediation status above records the subsequent implementation and validation.

## Recommended correction and release checks

1. Select a model appropriate for the device before loading. Evaluate `base.en` as the normal default and `tiny.en` on constrained devices, with speech-following accuracy and latency measured before release. Keep prewarming enabled. Generate the download disclosure from the selected model rather than repeating a hardcoded 150 MB string.
2. Separate download, specialization/loading, tokenizer setup, and microphone startup. Use the library's real progress/state callbacks and an indeterminate indicator for stages without measurable progress.
3. Validate required model assets and tokenizer readiness. Record completion only after successful setup; repair verified corruption by invalidating the affected files and corresponding download metadata. Preserve valid assets when an error is merely connectivity or device initialization failure.
4. Keep one owned startup task, share or reject concurrent starts, and cancel it on stop/dismissal. Check cancellation before enabling audio or publishing success.
5. Surface audio and model errors through one recoverable UI state, including retry and a way to leave setup. Request/check microphone permission and validate the input format before starting capture.
6. Add persistent startup-phase diagnostics and measure device memory during cold and cached loads. Validate a first download, interruption/resume, missing tokenizer, damaged cache, offline startup, low storage, denied microphone access, and dismissal/reopening during loading on the oldest supported hardware.

Do not present the fixed-speed setting as a verified workaround: the current teleprompter does not read `settings.scrollMode` or `fixedScrollSpeed`; those values currently appear only in the settings/model code.

## Evidence needed to close the customer's incident

Obtain the device model, OS version, app version, approximate failure time, and whether the app returned to the Home Screen or remained on the loading view. For an actual exit, obtain a VoicePrompter crash report and/or the corresponding JetsamEvent report from device Analytics Data. [Apple explains that memory-pressure termination can look like a crash and is diagnosed using jetsam reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports). Use the termination reason or native backtrace to distinguish memory exhaustion, watchdog termination, a Core ML failure, or an audio assertion before declaring the root cause confirmed.
