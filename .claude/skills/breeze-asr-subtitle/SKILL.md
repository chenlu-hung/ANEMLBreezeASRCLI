---
name: breeze-asr-subtitle
description: Generate Traditional-Chinese-optimized subtitles for video/audio using the on-device Breeze-ASR-25 (WhisperKit) model, then correct (and optionally translate) them by dispatching to opencode. Use when the user wants to transcribe a video/audio file to SRT, generate/make subtitles, 上字幕, 生成字幕/逐字稿, 影片轉字幕, 字幕校正, or translate subtitles to another language.
---

# breeze-asr-subtitle

End-to-end subtitle pipeline: **ASR runs locally in Swift (Breeze-ASR-25); LLM
correction & translation are delegated to opencode via the dispatch skill.**

```
video/audio → breeze-asr CLI (FFmpeg + Breeze-ASR-25) → raw.srt
            → opencode corrects text (timings locked by srt_tool.py) → final SRT
            → [optional] opencode translates → translated SRT
```

## Prerequisites (check once)

- CLI binary: `/Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.build/release/breeze-asr`
  If missing: `cd /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI && swift build -c release` (first build ~1 min).
- FFmpeg on PATH (`brew install ffmpeg`). The Breeze model is reused from an existing
  ANEMLBreezeASR/VibeTyping cache — no download if either app already has it.
- Safety-net script: `/Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py`.

## Workflow

1. **Transcribe.** Run the CLI; capture stdout (the SRT path). `-l` is the source
   language (default `auto`; use `zh` for Mandarin). Progress goes to stderr.
   ```bash
   breeze-asr "<input>" -l <lang> -o "<workdir>/raw.srt"
   ```
   Heavy step — if it may exceed a couple of minutes, run it in the background and poll.

2. **Auto-correct (default ON).** Use the **dispatch skill** to send a self-contained
   brief to **opencode** to context-correct (按照上下文校正) `raw.srt` into `corrected.srt`,
   keeping cue count + timestamps. The brief MUST keep the user's tested constraint verbatim:
   **「由你直接動手，禁止撰寫程式或呼叫外部 API」** (opencode corrects with its own model — no
   scripts, no external API). Exact brief → [REFERENCE.md](REFERENCE.md).

3. **Lock timings.** Never trust the LLM's timestamps — rebuild from the original:
   ```bash
   python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py reattach "<workdir>/raw.srt" "<workdir>/corrected.srt" "<final>.srt"
   ```
   Report the printed `cues=N mismatches=M`; investigate if mismatches > 0.

4. **Translate (only when asked).** If the user wants another language, dispatch opencode
   again to translate the corrected SRT (same verbatim constraint: 由你直接動手，禁止撰寫
   程式或呼叫外部 API), then reattach with `--fallback empty`:
   ```bash
   python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py reattach "<final>.srt" "<translated_llm>.srt" "<final>.<lang>.srt" --fallback empty
   ```

5. **Report** the final SRT path(s). Default output sits next to the input file.

## Notes

- Languages: `zh en ja ko es fr de it pt ru ar hi auto`.
- Subtitle **burning** into video is out of scope (use FFmpeg directly if needed).
- No chunking needed: send the **whole** SRT in a single opencode/agy task. The full file
  fits the context window (field-tested on opencode and agy), and whole-transcript context
  gives better correction/translation than stitching independently-corrected chunks. (The
  dubbing-branch `merge` is a different thing — it coalesces cues to cut TTS calls, not to
  fit context.)
- Troubleshooting (hangs, TCC, model cache) → [REFERENCE.md](REFERENCE.md#troubleshooting).
