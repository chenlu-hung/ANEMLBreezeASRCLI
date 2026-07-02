---
name: breeze-asr-dub
description: Generate a translated-language dubbed video from a video/audio file — extends breeze-asr-subtitle (local Breeze-ASR-25 transcription + opencode-corrected/translated SRT) with a final `breeze-asr dub` TTS + mux step (cloud edge-tts by default, optional voice cloning). Use when the user wants a dubbed video, 影片配音, 幫影片配音, 生成配音影片, 把影片翻成英文/中文配音, dub a video, voice-over a video, translate and dub.
---

# breeze-asr-dub

Extends **breeze-asr-subtitle**: same local ASR + opencode-corrected/translated SRT
pipeline, plus a final step that turns the translated SRT into spoken audio and muxes it
back into the source video.

```
video → breeze-asr CLI → raw.srt
      → [dub-only] srt_tool.py merge          → merged.srt   (fewer, longer cues — cheaper TTS)
      → opencode corrects (timings locked)     → corrected.srt
      → opencode translates (dub prompt: terse + abbreviations spelled out) → translated.srt
      → sanitize for the strict SRT parser
      → breeze-asr dub --srt translated.srt    → dubbed video (out.mp4)
```

## Prerequisites (check once)

- Everything breeze-asr-subtitle needs (CLI binary at
  `/Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.build/release/breeze-asr`, build with
  `swift build -c release` if missing; FFmpeg on PATH; `srt_tool.py` from that skill).
- Cloud dub (default engine) needs only an internet connection — nothing else to install.
- Voice cloning (`--clone`/`--ref`, opt-in) needs a built `indextts2-mlx` sibling repo —
  see [REFERENCE.md](REFERENCE.md#voice-cloning-opt-in).
- Any run with more than a couple minutes of TTS must be wrapped in `caffeinate -dimsu` or
  macOS idle-sleep silently kills the background job — see [REFERENCE.md](REFERENCE.md#long-runs-need-caffeinate).

## Workflow

1. **Transcribe.** Same as breeze-asr-subtitle step 1:
   ```bash
   breeze-asr "<input>" -l <lang> -o "<workdir>/raw.srt"
   ```
   Heavy step — background + poll if it may exceed a couple of minutes.

2. **Merge cues (dubbing-only, do this before correction).** TTS cost is dominated by the
   *number* of synth calls, not audio length, so coalesce the raw VAD cues into fewer,
   longer utterances first:
   ```bash
   python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py \
     merge "<workdir>/raw.srt" "<workdir>/merged.srt"
   ```
   Tune `--max-gap` / `--max-dur` / `--max-chars` if lines are still too fragmented.

3. **Auto-correct.** Dispatch to opencode with the correction prompt (same verbatim
   constraint as breeze-asr-subtitle: 由你直接動手，禁止撰寫程式或呼叫外部 API; full prompt
   → [REFERENCE.md](../breeze-asr-subtitle/REFERENCE.md#dispatching-correction-to-opencode)),
   input `merged.srt` → `corrected_llm.srt`. Then lock timings **against `merged.srt`**
   (not `raw.srt` — the merge step already re-timed the cues):
   ```bash
   python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py \
     reattach "<workdir>/merged.srt" "<workdir>/corrected_llm.srt" "<workdir>/corrected.srt"
   ```
   Report the printed `cues=N mismatches=M`; investigate if mismatches > 0.

4. **Translate with the dubbing-specific prompt.** Dispatch to opencode using the terse,
   TTS-friendly variant of the translation prompt (time-budgeted lines, every abbreviation
   spelled out so it's pronounceable) — exact prompt →
   [REFERENCE.md](REFERENCE.md#translation-prompt-dub-variant). Input `corrected.srt` →
   output `translated_llm.srt`.

   **Before reattaching, check the raw cue count matches** — `reattach`'s own
   `mismatches` counter does NOT catch a malformed arrow that silently merges two cues
   into one (the shifted-but-non-empty text after that point just looks like a normal
   translation, `mismatches` stays 0). Compare counts explicitly:
   ```bash
   python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py count "<workdir>/corrected.srt"
   python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py count "<workdir>/translated_llm.srt"
   ```
   If the counts differ, fix the malformed block in `translated_llm.srt` (or re-dispatch)
   before reattaching — every cue past that point would otherwise be silently misaligned.
   Once counts match, reattach with `--fallback empty`:
   ```bash
   python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py \
     reattach "<workdir>/corrected.srt" "<workdir>/translated_llm.srt" "<workdir>/translated.srt" --fallback empty
   ```

5. **Sanitize before the long synth run.** `breeze-asr dub` strict-parses `--srt`
   (SwiftSubtitles) and fails the **whole file** on the first malformed block — one bad
   arrow or embedded newline kills a 20+ minute run partway through. `srt_tool.py validate`
   only confirms the file parses to a non-zero cue count — it does **not** catch the
   silent-absorption case (that's what step 4's count comparison is for). Before running
   dub: fix any `--` arrows to `-->`, flatten every cue's text to a single line, drop empty
   cues, ensure a trailing blank line, then run `validate` as a final sanity check. Details →
   [REFERENCE.md](REFERENCE.md#sanitizing-the-srt).

6. **Dub.** Pick a voice matching the **target** language (wrong-language voice = garbled
   audio) and wrap in `caffeinate` for anything non-trivial:
   ```bash
   caffeinate -dimsu breeze-asr dub "<input>" --srt "<workdir>/translated.srt" \
     --voice <voice-for-target-lang> -o "<out>.mp4"
   ```
   Defaults already give `--stretch-video` (natural-speed dub, video freeze-extended at
   dense cues so nothing overlaps, hardware VideoToolbox re-encode) — this is the preferred
   timeline mode for lecture-style content. Full option/voice table and mode overrides →
   [REFERENCE.md](REFERENCE.md#dub-options).

7. **Report.** stdout of `breeze-asr dub` is the final video path — report that (and the
   translated SRT path, in case the user also wants the plain subtitle file alongside it).

## Notes

- This is a **superset** of breeze-asr-subtitle, not a replacement — if the user only wants
  subtitles (no dubbed audio/video), use breeze-asr-subtitle and stop after translation.
- If the user already has a corrected/translated SRT from a prior breeze-asr-subtitle run
  (built for *reading*, i.e. **not** merged/dub-worded), it can still be dubbed, but expect
  more, shorter TTS calls (slower) and possibly tighter cues (more stretch/overlap) — offer
  to redo translation with the dub-specific prompt for a better result.
- No chunking for the opencode correct/translate calls: send the **whole** SRT in one task
  (same reasoning as breeze-asr-subtitle — full-file context beats stitched chunks).
- Troubleshooting → [REFERENCE.md](REFERENCE.md#troubleshooting).
