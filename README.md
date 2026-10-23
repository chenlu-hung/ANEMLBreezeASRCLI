# breeze-asr

A headless macOS command-line tool that transcribes audio/video to subtitles with the
on-device **Breeze-ASR-25** model (via [WhisperKit](https://github.com/argmaxinc/WhisperKit)),
and can synthesise a **time-aligned dub** from a translated SRT — cloud neural TTS by
default, or a voice-cloned local dub as an opt-in.

The CLI itself does **ASR only** — speech to SRT. Subtitle correction and translation are
intentionally left to an LLM step, and turning a dub's SRT into pronounceable, time-budgeted
lines is a judgment call, not something a flag can do. That's exactly what the two **agent
skills** below automate end-to-end.

## Agent skills (recommended)

This repo vendors two Agent Skills under [`.agents/skills/`](.agents/skills), shared by
Claude Code, Codex, opencode and Antigravity (`agy`) — an agent working in this repo picks
them up automatically, no install step needed. (`.claude/skills` is a symlink to the same
directory for Claude Code; repo instructions live in [`AGENTS.md`](AGENTS.md), with
`CLAUDE.md` symlinked to it.)

### [`breeze-asr-subtitle`](.agents/skills/breeze-asr-subtitle/SKILL.md) — transcribe → correct → translate

```
video/audio → breeze-asr CLI (FFmpeg + Breeze-ASR-25) → raw.srt
            → opencode corrects text (timings locked by srt_tool.py) → final SRT
            → [optional] opencode translates → translated SRT
```

Ask for things like "生成字幕", "上字幕", "轉成 SRT", "translate these subtitles to
English". The skill runs the CLI locally for ASR, then dispatches correction/translation to
**opencode** (via the `dispatch` skill) so the LLM only ever touches cue *text* —
`srt_tool.py reattach` always rebuilds timestamps from the original cues, regardless of what
the LLM does to them.

### [`breeze-asr-dub`](.agents/skills/breeze-asr-dub/SKILL.md) — transcribe → translate → dub

```
video → breeze-asr CLI → raw.srt
      → [dub-only] srt_tool.py merge          → merged.srt   (fewer, longer cues — cheaper TTS)
      → opencode corrects (timings locked)     → corrected.srt
      → opencode translates (dub prompt: terse + abbreviations spelled out) → translated.srt
      → sanitize for the strict SRT parser
      → breeze-asr dub --srt translated.srt    → dubbed video (out.mp4)
```

Ask for things like "幫這部影片配音", "dub this video to English", "把講座配成英文配音".
Extends `breeze-asr-subtitle` with a dubbing-tuned translation prompt (terse, time-budgeted,
every abbreviation spelled out so TTS pronounces it correctly) and a final `breeze-asr dub`
call — cloud edge-tts by default, voice cloning opt-in.

Both skills dispatch the correction/translation step to a separate **opencode** CLI (free,
its own sign-in) via the `dispatch` skill, and reuse
[`srt_tool.py`](.agents/skills/breeze-asr-subtitle/scripts/srt_tool.py) as an SRT
safety net (reattach original timings, merge cues, validate). See each skill's `SKILL.md`
for the numbered workflow and `REFERENCE.md` for exact prompts, CLI flags, and
troubleshooting.

## Requirements

- macOS 13 or later
- [FFmpeg](https://ffmpeg.org/) — `brew install ffmpeg`
- For the `dub` subcommand's **default** cloud TTS: nothing extra — just an internet connection.
- For **voice cloning** (`--clone`/`--ref`, opt-in): a built [indextts2-mlx](https://github.com/chenlu-hung/indextts2-mlx) CLI,
  located via the `--indextts2` / `--model` flags (defaults follow a `../indextts2-mlx/`
  sibling-repo layout).
- For the **agent skills**: a signed-in `opencode` CLI and Python 3 (for
  `srt_tool.py`) — see [Agent skills](#agent-skills-recommended) above.

## Install

The skills expect the binary at `.build/release/breeze-asr` (and call it as `breeze-asr`,
so put it on your `PATH` too). Either download the prebuilt one or build from source.

**Prebuilt (Apple silicon, macOS 13+)** — from [Releases](https://github.com/chenlu-hung/ANEMLBreezeASRCLI/releases):

```bash
mkdir -p .build/release
curl -L https://github.com/chenlu-hung/ANEMLBreezeASRCLI/releases/download/v0.2.0/breeze-asr-macos-arm64-v0.2.0.tar.gz \
  | tar xz -C .build/release
xattr -d com.apple.quarantine .build/release/breeze-asr 2>/dev/null  # only if downloaded via a browser
```

**From source:**

```bash
swift build -c release
# binary: .build/release/breeze-asr
```

Then link it onto your `PATH`, e.g. `ln -sf "$PWD/.build/release/breeze-asr" ~/.local/bin/breeze-asr`.

## Manual CLI usage

The skills above cover the common end-to-end flows. Use the CLI directly for scripting, CI,
or any step in isolation.

### Transcription

```bash
breeze-asr <input> [-l <lang>] [-o <out.srt>] [--model-path <dir>] [--compute <ane|gpu>] [-q]
```

| Option | Meaning |
| --- | --- |
| `<input>` | Any audio/video file FFmpeg can read |
| `-l, --language <code>` | Source language: `zh en ja ko es fr de it pt ru ar hi auto` (default `auto`) |
| `-o, --output <path>` | Output SRT path (default: `<input>.srt`) |
| `--model-path <dir>` | Use a specific Breeze-ASR-25 model folder |
| `--compute <backend>` | Compute units: `ane` (default) or `gpu`. See [Design notes](#design-notes) — the first ANE run does a one-time ~40 min compile, then caches and loads in ~3 s; use `gpu` for an instant load when the ANE cache is cold |
| `-q, --quiet` | Suppress progress output |

- **stdout** prints the final SRT path (capture this); **stderr** carries progress and logs.
- Pipeline: FFmpeg extracts a 16 kHz mono WAV → WhisperKit/Breeze-ASR-25 transcribes with
  VAD chunking → a standard SRT is written.

```bash
breeze-asr lecture.mp4 -l zh -o lecture.srt
```

### Dubbing (`dub` subcommand)

Synthesise a **time-aligned dub** from a translated SRT and mux it back into the video. By
default, speech is generated by **cloud edge-tts** (Microsoft neural voices) via the python
[edge-tts](https://github.com/rany2/edge-tts) CLI — free and natural; install it with
`pip install edge-tts` (put it on PATH or pass `--edge-tts <path>`) and have an internet
connection. If Microsoft changes the protocol and synthesis starts failing, `pip install -U edge-tts`. Pass `--clone` (or `--ref`)
to switch to a local **indextts2-mlx** CLI instead, which clones the original speaker's
voice. Either way breeze-asr owns the timeline placement and audio/video assembly.

```bash
breeze-asr dub <video> --srt <translated.srt> [-o out.mp4] [options]
```

#### Cloud voice (default)

```bash
breeze-asr dub lecture.mp4 --srt lecture.en.srt -o lecture.en.mp4
```

| Option | Meaning |
| --- | --- |
| `--tts <cloud\|local>` | Force the TTS engine (default: `cloud`) |
| `--voice <id>` | Cloud voice id (default: `en-US-AndrewMultilingualNeural`, natural en-US male — the repo mainly dubs *to* English). For a Chinese dub use e.g. `zh-TW-YunJheNeural` (雲哲). A voice from the wrong language mangles the other. |

#### Voice cloning (opt-in)

Pass `--clone` (or `--ref`) to clone the original speaker with the local indextts2-mlx CLI
instead of the cloud voice. By default the reference is extracted straight from the source
video — no external sample needed.

| Option | Meaning |
| --- | --- |
| `--clone` | Clone the original speaker (switches the engine to local indextts2) |
| `--ref <wav>` | Explicit voice reference instead of extracting one from the video (implies `--clone`) |
| `--ref-start <sec>` | Start of the auto-extracted reference clip (default: the first cue's start) |
| `--ref-duration <sec>` | Length of the auto-extracted reference clip (default: 15) |
| `--indextts2 <path>` / `--model <dir>` | indextts2 binary / model dir (defaults follow `../indextts2-mlx/`) |
| `--preproc-dir <dir>` | indextts2 preprocessing-weights dir (optional) |
| `--steps <n>` | indextts2 diffusion steps per cue (1–100, default 20). Fewer steps synthesise faster with slightly lower quality (engine default is 25) |

#### Core options

| Option | Meaning |
| --- | --- |
| `--srt <path>` | Translated SRT to voice (**required**) |
| `-o, --output <path>` | Output video (default: `<video>.dubbed.mp4`) |
| `--keep-original <vol>` | Duck the original audio at this volume under the dub (`0` = replace, default) |
| `--no-trim-silence` | Keep the TTS clip's leading/trailing silence (default: trim it for tighter onset sync and less speed-up) |
| `--wav-dir <dir>` | Reuse already-generated clips and skip TTS (cheap iteration — synthesis is the slow part) |
| `--fit-rate <pct>` | (cloud) Slow each sparse cue by up to pct% (edge-tts `--rate`) so its speech fills ~90% of the time until the next cue, instead of rushing then going silent |
| `--compress-gaps <f>` | (stretch) Fast-forward the silence left after each cue's speech at ×f — output gets shorter, no long dead air |
| `--gap-pause <sec>` | (compress-gaps) Pause kept at normal speed after each cue's speech (default 0.5) |
| `--no-burn-subs` | Don't burn subtitles into the video (they are burned by default) |
| `--ffmpeg <path>` | Use this ffmpeg for everything |
| `-q, --quiet` | Suppress progress output |

- **stdout** prints the dubbed video path; the per-cue **timeline report** goes to stderr.
- **Subtitles are burned in by default**: the dub's text, split into ≤2-line chunks and timed
  to the dubbed speech on the *output* timeline (also saved as `<output>.srt`). Burning needs
  an ffmpeg built with libass; Homebrew's default `ffmpeg` has none, so `dub` falls back to
  another install that does (`brew install ffmpeg-full`, or a conda-forge ffmpeg), or pass
  `--ffmpeg <path>`. In stream-copy modes, burning forces one video re-encode.

#### Timing modes

Cross-language dubbing is a trilemma — when the target language runs longer than the source
you cannot have uniform speech speed, zero drift, and zero overlap all at once. Pick a mode:

- **Stretch video (default)** — `--stretch-video`. Keeps the dub at natural speed and
  freeze-extends the video at dense cues so nothing overlaps and audio/video stay locked.
  The output video ends up a little longer (brief freezes at the densest moments) — best for
  static lecture content. Honours `--speed` to cap how much the video grows. **Re-encodes the
  whole video** — VideoToolbox hardware encoding by default (minutes, not tens of minutes, on
  a long 1080p60 clip); pass `--sw-encode` for a slower libx264 pass at marginally higher
  quality. `--no-stretch-video` disables this and falls back to sequential placement.
  Add `--compress-gaps <f>` to fast-forward the silence after each line instead (shorter
  output, no dead air) — for lectures, `--fit-rate 15 --compress-gaps 3` pairs well: lines are
  slowed a little to fill their slot, and what silence remains plays at ×3. The timeline is
  frame-exact (60 fps, whole-frame segments), so audio never drifts across hundreds of cuts.
- **Uniform speed** — `--uniform-speed`. One global `atempo`, every cue anchored at its own
  start time → constant rate and zero drift, at the cost of the tightest lines overlapping
  the next cue locally. `--speed <f>` forces the tempo (otherwise it auto-fits the video
  length). Stream-copies the video (`-c:v copy`), no re-encode.
- **Sequential** — `--no-stretch-video` without `--uniform-speed`. `--max-speedup <f>`
  (1.0–2.0, default 1.5). Each clip starts no earlier than its cue and the previous clip's
  end, sped up (capped) to fit the gap. Never overlaps, but the speech rate varies and
  timing drifts when the dub runs long. Also stream-copies the video.

#### Pipeline

SRT cues → **cloud**: edge-tts CLI per cue, 4 at a time (retried a few times on empty audio),
or **clone**: extract voice reference from the video → indextts2, one clip per cue →
`<stem>_NNN.wav` → trim clip silence → place per the chosen timing mode → `amix` dub track,
or `tpad`+`concat` plus a hardware/software re-encode for the stretched video → mux
(`-c:v copy` where the video is untouched, AAC audio).

> **Adaptation tip:** the cleanest dubs come from keeping each translated line *terse* so it
> fits its slot at a natural rate. When translating an SRT for dubbing, also instruct the
> translator to spell out abbreviations into full pronounceable words (e.g. `cos` → cosine,
> `tan` → tangent) so the TTS reads them correctly. The `breeze-asr-dub` skill already bakes
> this into its translation prompt.

```bash
breeze-asr dub lecture.mp4 --srt lecture.en.srt -o lecture.en.mp4            # cloud + stretch-video + burned subs (defaults)
breeze-asr dub lecture.mp4 --srt lecture.en.srt --fit-rate 15 --compress-gaps 3 -o lecture.en.mp4  # paced for lectures
breeze-asr dub lecture.mp4 --srt lecture.zh.srt --voice zh-TW-YunJheNeural -o lecture.zh.mp4
breeze-asr dub lecture.mp4 --srt lecture.en.srt --clone -o lecture.en.mp4    # voice-cloned instead
```

## Design notes

- **Model resolution**: `--model-path` wins; otherwise it reuses a cached
  `aoiandroid/Breeze-ASR-25_coreml` model if present, and only downloads it (~3 GB) when no
  cache is found.
- **Compute units default to the ANE (`.cpuAndNeuralEngine`); `--compute gpu` switches to
  `.cpuAndGPU`.** The NPU beats the GPU for this model on Apple silicon, so ANE is the default.
  ANE is *not* a deadlock here (an old too-early kill made it look like one): the first ANE run
  does a one-time cold compile of the 1.2 GB encoder that can take ~40 min, after which it is
  cached (per bundle id, under `~/Library/Caches/breeze-asr/`) and later loads take ~3 s. On a
  fresh machine or wiped cache that first run looks like a hang — use `--compute gpu` for an
  instant load when a warm ANE cache isn't available.
- **`tokenizerFolder` is pinned** to an app-support cache. WhisperKit otherwise writes the
  Whisper tokenizer to `~/Documents/huggingface`, which is TCC-protected for a CLI and fails
  with a misleading "could not remove corrupted metadata file" error.
- **Synchronous `main` + `dispatchMain()`**: the real work runs on a detached Task while the
  main thread services the main queue, so CoreML/ANE completions are delivered and the model
  load doesn't deadlock.
