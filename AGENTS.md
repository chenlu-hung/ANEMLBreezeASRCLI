# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, opencode, Antigravity/agy)
when working with code in this repository.

> `AGENTS.md` is the single source of truth; `CLAUDE.md` is a symlink to it. Agent Skills live
> in `.agents/skills/` (read by Codex, opencode and agy); `.claude/skills` is a symlink to it for
> Claude Code. Edit the real files, never the symlinks.

## Project map
A `.projectmap/` index exists — use it before broad exploration:
- Read `.projectmap/ARCHITECTURE.md` for the module map, entry points, and conventions.
- To locate a symbol, grep `.projectmap/tags` (ctags format) instead of scanning the repo.
- Open `.projectmap/modules/<name>.md` only for the module you're working in.
Re-run `/project-map update` after substantial changes.

## Build / test / run
- Build: `swift build` (release: `swift build -c release` → `.build/release/breeze-asr`)
- Prebuilt arm64 binary: GitHub release `v0.1.0` (`breeze-asr-macos-arm64-v0.1.0.tar.gz`, a bare
  `breeze-asr` executable — extract into `.build/release/`). Rebuild/re-release if `Sources/` changes.
- Test: `swift test` — **no test target is defined yet**, so this is currently a no-op.
- Transcribe: `breeze-asr <input> [-l zh] [-o out.srt]`
- Dub: `breeze-asr dub <video> --srt <translated.srt> [-o out.mp4]`
- Requires FFmpeg on PATH (`brew install ffmpeg`).
- **Dub TTS default = cloud edge-tts** (Microsoft neural voices; free, natural, *no* cloning).
  Runs the **python `edge-tts` CLI** per cue (`pip install edge-tts`, e.g. in a conda env; found on
  PATH or via `--edge-tts <path>`) plus an internet connection. It replaced the native SwiftEdgeTTS
  client after Microsoft's 2026-10 `Sec-MS-GEC` v2 change broke it — python edge-tts tracks protocol
  changes promptly, so a future break is fixed with `pip install -U edge-tts`, no rebuild. Default voice `en-US-AndrewMultilingualNeural` (natural en-US
  male — the repo mainly dubs *to English*); pick another with `--voice` (e.g. `zh-TW-YunJheNeural`
  雲哲 for a Chinese dub).
- **Dub timeline default = `--stretch-video`** (dub at natural speed, freeze-extend the video at
  dense cues so nothing overlaps; output ends up slightly longer). `--no-stretch-video` falls back to
  sequential; `--uniform-speed`/`--speed` switch to constant-speed anchoring (and override the default).
- **Stretch timeline is frame-exact**: the source is resampled to 60 fps and every segment is cut
  and sized in whole frames (`trim=start_frame/end_frame`, `tpad=stop=`, even-drop `select`), and
  audio is placed from the same frame counts — keep it that way or hundreds of segments drift.
- **Pacing options** (off by default): `--compress-gaps <f>` fast-forwards each cue's leftover
  silence (after speech + `--gap-pause`, default 0.5 s) at ×f on the stretch timeline;
  `--fit-rate <pct>` re-synthesises sparse cloud cues up to pct% slower (edge-tts `--rate`) so speech
  fills ~90% of the slot. Lecture dubs use `--fit-rate 15 --compress-gaps 3`.
- **Subtitles are burned in by default** (`--no-burn-subs` to skip): cue text re-split into ≤2-line
  chunks timed to the placed speech on the *output* timeline, also written as `<output>.srt`. Needs an
  ffmpeg with libass — Homebrew's default lacks it, so `dub` auto-picks another install (ffmpeg-full,
  conda envs; `FFmpegService.findFFmpeg(withFilter:)`) unless `--ffmpeg` pins one.
- **Re-encoding** (stretch, or burning in other modes) defaults to the **VideoToolbox hardware
  encoder** (`h264_videotoolbox -q:v 65`) so a long 1080p60 re-encode takes minutes, not tens of
  minutes. `--sw-encode` forces libx264 (slower, marginally higher quality). Otherwise `-c:v copy`.
- **Voice cloning is opt-in**: `--clone` (or passing `--ref`) switches to the local indextts2-mlx
  CLI, which clones the original speaker. That path needs a built indextts2-mlx (defaults follow a
  `../indextts2-mlx/` sibling-repo layout, overridable via `--indextts2` / `--model`).

## Architecture
Single executable target (`Sources/breeze-asr`), thin `@main` entry delegating to focused services:
- **Transcribe path**: `FFmpegService` (extract 16 kHz mono WAV) → `WhisperKitService`
  (Breeze-ASR-25 via WhisperKit, VAD chunking) → `SubtitleService` (write SRT).
- **Dub path** (`dub` subcommand): `DubbingService` synthesises per-cue speech — by default via the
  cloud **edge-tts** engine (`synthesiseCloud` → `synthesiseCue` → `runEdgeTTS`, shelling out to the
  python `edge-tts` CLI, 4 cues in flight; fixed neural voice, no reference), or via the local **indextts2** CLI when `--clone`/`--ref`
  is given (`resolveReference` from the source video → `synthesise`). Either way clips are named
  `<stem>_<NNN>.wav`, then placed on the timeline (default **stretch-video**; also sequential /
  uniform-speed) and muxed with FFmpeg. Each edge-tts cue is retried a few times (the endpoint
  intermittently returns no audio).
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
