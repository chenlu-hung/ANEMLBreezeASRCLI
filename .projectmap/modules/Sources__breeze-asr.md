# Module: `Sources/breeze-asr`

## Summary
The entire CLI lives here. `BreezeASRCLI` is the `@main` entry point: it parses args (`Options`
for transcription, `DubOptions` for the `dub` subcommand) and runs the work on a detached Task
while the main thread stays in `dispatchMain()` — required so CoreML/ANE completions are
serviced and the model load doesn't deadlock. The transcription path is `FFmpegService`
(extract 16 kHz mono WAV) → `WhisperKitService` (Breeze-ASR-25 with VAD chunking, model-cache
resolution) → `SubtitleService` (write SRT via SwiftSubtitles), with `SupportedLanguage`
mapping language codes to Whisper. The `dub` path is `DubbingService`: by default it
synthesises per-cue speech via the cloud edge-tts engine (`synthesiseCloud`/`synthesiseCue`
using the native SwiftEdgeTTS package, fixed neural voice, no cloning), or — when
`--clone`/`--ref` is given — extracts a voice reference and drives the external indextts2 CLI
(`synthesise`). It then places clips on the timeline (default stretch-video, plus sequential /
uniform-speed) and muxes the result with FFmpeg; stretch-video is the only mode that
re-encodes (VideoToolbox hardware encoder by default).

<!-- projectmap:auto:start (generated — do not edit by hand) -->
## Files (6)
- `Sources/breeze-asr/BreezeASRCLI.swift`
- `Sources/breeze-asr/DubbingService.swift`
- `Sources/breeze-asr/FFmpegService.swift`
- `Sources/breeze-asr/SubtitleService.swift`
- `Sources/breeze-asr/SupportedLanguage.swift`
- `Sources/breeze-asr/WhisperKitService.swift`

## Public symbols (57)
- `struct BreezeASRCLI` — Sources/breeze-asr/BreezeASRCLI.swift:11
- `function main` — Sources/breeze-asr/BreezeASRCLI.swift:16
- `function run` — Sources/breeze-asr/BreezeASRCLI.swift:63
- `function runDub` — Sources/breeze-asr/BreezeASRCLI.swift:114
- `function log` — Sources/breeze-asr/BreezeASRCLI.swift:161
- `function logDone` — Sources/breeze-asr/BreezeASRCLI.swift:166
- `function progressBar` — Sources/breeze-asr/BreezeASRCLI.swift:171
- `function printUsage` — Sources/breeze-asr/BreezeASRCLI.swift:177
- `function printDubUsage` — Sources/breeze-asr/BreezeASRCLI.swift:209
- `struct CLIError` — Sources/breeze-asr/BreezeASRCLI.swift:276
- `enum TTSEngine` — Sources/breeze-asr/BreezeASRCLI.swift:279
- `struct Options` — Sources/breeze-asr/BreezeASRCLI.swift:284
- `struct DubOptions` — Sources/breeze-asr/BreezeASRCLI.swift:340
- `enum Defaults` — Sources/breeze-asr/BreezeASRCLI.swift:363
- `function value` — Sources/breeze-asr/BreezeASRCLI.swift:387
- `function absolute` — Sources/breeze-asr/BreezeASRCLI.swift:478
- `struct DubbingService` — Sources/breeze-asr/DubbingService.swift:10
- `struct Config` — Sources/breeze-asr/DubbingService.swift:11
- `struct Placement` — Sources/breeze-asr/DubbingService.swift:36
- `function dub` — Sources/breeze-asr/DubbingService.swift:53
- `function resolveReference` — Sources/breeze-asr/DubbingService.swift:206
- `function synthesise` — Sources/breeze-asr/DubbingService.swift:228
- `function synthesiseCloud` — Sources/breeze-asr/DubbingService.swift:278
- `function synthesiseCue` — Sources/breeze-asr/DubbingService.swift:314
- `struct Segment` — Sources/breeze-asr/DubbingService.swift:342
- `function dubWithStretchedVideo` — Sources/breeze-asr/DubbingService.swift:355
- `function buildStretchedVideo` — Sources/breeze-asr/DubbingService.swift:415
- `function trimSilence` — Sources/breeze-asr/DubbingService.swift:459
- `function atempoChain` — Sources/breeze-asr/DubbingService.swift:477
- `function buildDubTrack` — Sources/breeze-asr/DubbingService.swift:491
- `function mux` — Sources/breeze-asr/DubbingService.swift:524
- `function reportTimeline` — Sources/breeze-asr/DubbingService.swift:547
- `function log` — Sources/breeze-asr/DubbingService.swift:579
- `function fmt` — Sources/breeze-asr/DubbingService.swift:584
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
- `SwiftEdgeTTS`
- `SwiftSubtitles`
- `WhisperKit`
<!-- projectmap:auto:end -->
