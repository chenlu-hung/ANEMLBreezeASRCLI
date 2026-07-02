# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project map
A `.projectmap/` index exists — use it before broad exploration:
- Read `.projectmap/ARCHITECTURE.md` for the module map, entry points, and conventions.
- To locate a symbol, grep `.projectmap/tags` (ctags format) instead of scanning the repo.
- Open `.projectmap/modules/<name>.md` only for the module you're working in.
Re-run `/project-map update` after substantial changes.

## Build / test / run
- Build: `swift build` (release: `swift build -c release` → `.build/release/breeze-asr`)
- Test: `swift test` — **no test target is defined yet**, so this is currently a no-op.
- Transcribe: `breeze-asr <input> [-l zh] [-o out.srt]`
- Dub: `breeze-asr dub <video> --srt <translated.srt> [-o out.mp4]`
- Requires FFmpeg on PATH (`brew install ffmpeg`).
- **Dub TTS default = cloud edge-tts** (Microsoft neural voices; free, natural, *no* cloning).
  Needs `edge-tts` on PATH (`pipx install edge-tts`) and an internet connection. Default voice
  `zh-TW-YunJheNeural` (雲哲, male); pick another with `--voice`.
- **Voice cloning is opt-in**: `--clone` (or passing `--ref`) switches to the local indextts2-mlx
  CLI, which clones the original speaker. That path needs a built indextts2-mlx (defaults follow a
  `../indextts2-mlx/` sibling-repo layout, overridable via `--indextts2` / `--model`).

## Architecture
Single executable target (`Sources/breeze-asr`), thin `@main` entry delegating to focused services:
- **Transcribe path**: `FFmpegService` (extract 16 kHz mono WAV) → `WhisperKitService`
  (Breeze-ASR-25 via WhisperKit, VAD chunking) → `SubtitleService` (write SRT).
- **Dub path** (`dub` subcommand): `DubbingService` synthesises per-cue speech — by default via the
  cloud **edge-tts** engine (`synthesiseCloud`, fixed neural voice, no reference), or via the local
  **indextts2** CLI when `--clone`/`--ref` is given (`resolveReference` from the source video →
  `synthesise`). Either way clips are named `<stem>_<NNN>.wav`, then placed on the timeline
  (sequential / uniform-speed / stretch-video modes) and muxed with FFmpeg. edge-tts is called
  once per cue with a few retries (the endpoint intermittently returns `NoAudioReceived`).
- This tool is **ASR-only**: subtitle correction and translation are deliberately left to an
  external LLM step — don't add them here.

## Critical constraints (non-obvious, easy to break)
- **stdout = result, stderr = everything else.** Transcribe prints the SRT path to stdout; dub
  prints the output video path. All progress bars, logs, and timeline reports go to stderr so
  callers can capture the result cleanly. Keep this split.
- **Synchronous `main` + `dispatchMain()`**: real work runs on a detached `Task` while the main
  thread services the main queue. An `async` main that loads the CoreML model on the main thread
  deadlocks.
- **Compute units default to `.cpuAndNeuralEngine` (ANE); `--compute gpu` switches to `.cpuAndGPU`.**
  ANE is the default because the NPU beats the GPU for this model on Apple silicon. ANE is *not* a
  deadlock in this unsigned CLI (the old "ANE deadlocks/never finishes" claim was a too-early kill):
  the first ANE run does a one-time cold compile of the 1.2 GB encoder that can take ~40 min, after
  which ANECompilerService caches it under the binary's bundle id (`breeze-asr`, in
  `~/Library/Caches/breeze-asr/com.apple.e5rt.e5bundlecache`) and later loads take ~3 s. That e5rt
  cache is per-bundle-id, so VibeTyping's warm ANE compile can't be inherited — only the `.mlmodelc`
  model files are shared. **Gotcha:** on a fresh machine / after a cache wipe / if the bundle id
  changes, the first default run will look like a ~40 min hang — use `--compute gpu` for an instant
  load when a warm ANE cache isn't available.
- **`tokenizerFolder` is pinned** to an app-support cache. WhisperKit otherwise writes the
  tokenizer to TCC-protected `~/Documents/huggingface`, failing with a misleading "could not
  remove corrupted metadata file" error.
- **Model cache reuse**: `--model-path` wins; otherwise reuse a cached `Breeze-ASR-25_coreml`
  model (validated by a real >100 MB AudioEncoder) and only download (~3 GB) if none is found.
- Errors are typed `LocalizedError` enums per service; `CLIError` carries user-facing messages.
