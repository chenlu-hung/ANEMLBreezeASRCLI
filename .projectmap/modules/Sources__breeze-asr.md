# Module: `Sources/breeze-asr`

## Summary
The entire CLI lives here. `BreezeASRCLI` is the `@main` entry point: it parses args (`Options`
for transcription, `DubOptions` for the `dub` subcommand) and runs the work on a detached Task
while the main thread stays in `dispatchMain()` — required so CoreML/ANE completions are
serviced and the model load doesn't deadlock. The transcription path is `FFmpegService`
(extract 16 kHz mono WAV) → `WhisperKitService` (Breeze-ASR-25 with VAD chunking, model-cache
resolution) → `SubtitleService` (write SRT via SwiftSubtitles), with `SupportedLanguage`
mapping language codes to Whisper. The `dub` path is `DubbingService`: it extracts a voice
reference from the source video (or takes `--ref`), drives the external indextts2 CLI for
per-cue speech, then places clips on the timeline (sequential / uniform-speed / stretch-video
modes) and muxes the result with FFmpeg.

<!-- projectmap:auto:start (generated — do not edit by hand) -->
## Files (6)
- `Sources/breeze-asr/BreezeASRCLI.swift`
- `Sources/breeze-asr/DubbingService.swift`
- `Sources/breeze-asr/FFmpegService.swift`
- `Sources/breeze-asr/SubtitleService.swift`
- `Sources/breeze-asr/SupportedLanguage.swift`
- `Sources/breeze-asr/WhisperKitService.swift`

## Public symbols (54)
- `struct BreezeASRCLI` — Sources/breeze-asr/BreezeASRCLI.swift:11
- `function main` — Sources/breeze-asr/BreezeASRCLI.swift:16
- `function run` — Sources/breeze-asr/BreezeASRCLI.swift:63
- `function runDub` — Sources/breeze-asr/BreezeASRCLI.swift:114
- `function log` — Sources/breeze-asr/BreezeASRCLI.swift:158
- `function logDone` — Sources/breeze-asr/BreezeASRCLI.swift:163
- `function progressBar` — Sources/breeze-asr/BreezeASRCLI.swift:168
- `function printUsage` — Sources/breeze-asr/BreezeASRCLI.swift:174
- `function printDubUsage` — Sources/breeze-asr/BreezeASRCLI.swift:206
- `struct CLIError` — Sources/breeze-asr/BreezeASRCLI.swift:259
- `struct Options` — Sources/breeze-asr/BreezeASRCLI.swift:261
- `struct DubOptions` — Sources/breeze-asr/BreezeASRCLI.swift:317
- `enum Defaults` — Sources/breeze-asr/BreezeASRCLI.swift:337
- `function value` — Sources/breeze-asr/BreezeASRCLI.swift:358
- `function absolute` — Sources/breeze-asr/BreezeASRCLI.swift:427
- `struct DubbingService` — Sources/breeze-asr/DubbingService.swift:9
- `struct Config` — Sources/breeze-asr/DubbingService.swift:10
- `struct Placement` — Sources/breeze-asr/DubbingService.swift:32
- `function dub` — Sources/breeze-asr/DubbingService.swift:49
- `function resolveReference` — Sources/breeze-asr/DubbingService.swift:194
- `function synthesise` — Sources/breeze-asr/DubbingService.swift:216
- `struct Segment` — Sources/breeze-asr/DubbingService.swift:263
- `function dubWithStretchedVideo` — Sources/breeze-asr/DubbingService.swift:276
- `function buildStretchedVideo` — Sources/breeze-asr/DubbingService.swift:336
- `function trimSilence` — Sources/breeze-asr/DubbingService.swift:370
- `function atempoChain` — Sources/breeze-asr/DubbingService.swift:388
- `function buildDubTrack` — Sources/breeze-asr/DubbingService.swift:402
- `function mux` — Sources/breeze-asr/DubbingService.swift:435
- `function reportTimeline` — Sources/breeze-asr/DubbingService.swift:458
- `function log` — Sources/breeze-asr/DubbingService.swift:490
- `function fmt` — Sources/breeze-asr/DubbingService.swift:495
- `enum FFmpegError` — Sources/breeze-asr/FFmpegService.swift:3
- `class FFmpegService` — Sources/breeze-asr/FFmpegService.swift:24
- `function findFFmpeg` — Sources/breeze-asr/FFmpegService.swift:31
- `function checkFFmpegAvailable` — Sources/breeze-asr/FFmpegService.swift:65
- `function getVideoDuration` — Sources/breeze-asr/FFmpegService.swift:71
- `function run` — Sources/breeze-asr/FFmpegService.swift:121
- `function extractReferenceClip` — Sources/breeze-asr/FFmpegService.swift:162
- `function extractAudio` — Sources/breeze-asr/FFmpegService.swift:173
- `enum SubtitleError` — Sources/breeze-asr/SubtitleService.swift:4
- `struct TranscriptionSegment` — Sources/breeze-asr/SubtitleService.swift:17
- `struct SubtitleService` — Sources/breeze-asr/SubtitleService.swift:27
- `function generateSRT` — Sources/breeze-asr/SubtitleService.swift:28
- `function timeIntervalToSubtitlesTime` — Sources/breeze-asr/SubtitleService.swift:48
- `enum SupportedLanguage` — Sources/breeze-asr/SupportedLanguage.swift:5
- `enum ComputeBackend` — Sources/breeze-asr/WhisperKitService.swift:15
- `enum WhisperKitError` — Sources/breeze-asr/WhisperKitService.swift:27
- `class WhisperKitService` — Sources/breeze-asr/WhisperKitService.swift:49
- `function appSupportCache` — Sources/breeze-asr/WhisperKitService.swift:62
- `function initialize` — Sources/breeze-asr/WhisperKitService.swift:82
- `function transcribe` — Sources/breeze-asr/WhisperKitService.swift:136
- `function findModelInCache` — Sources/breeze-asr/WhisperKitService.swift:193
- `function isValidModelFolder` — Sources/breeze-asr/WhisperKitService.swift:219
- `function directorySize` — Sources/breeze-asr/WhisperKitService.swift:232

## Dependencies (imports)
- `CoreML`
- `Foundation`
- `Hub`
- `SwiftSubtitles`
- `WhisperKit`
<!-- projectmap:auto:end -->
