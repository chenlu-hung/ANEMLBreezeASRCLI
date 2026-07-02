# breeze-asr-dub — Reference

## Translation prompt (dub variant)

Same shape as breeze-asr-subtitle's translation dispatch, with an appended dubbing block.
Keep the core constraint verbatim: **「由你直接動手，禁止撰寫程式或呼叫外部 API」**.

```
把這份中文字幕檔翻譯成英文字幕並存成另一個 srt 檔。禁止更動字幕的時間軸。由你直接動手，禁止撰寫程式或呼叫外部 API。

輸入檔：  <workdir>/corrected.srt
輸出檔：  <workdir>/translated_llm.srt

規則：保持完全相同的字幕條目數量與順序，不要合併、拆分、增加或刪除任何條目；
每條的編號與時間軸原樣保留，只改文字行；輸出純 SRT，不要加說明或 markdown 程式碼框。

這份翻譯會用來做配音（TTS 朗讀），所以每一條請盡量「簡短口語」：在不漏掉重點的前提下，
用最精簡的字數表達，能省的虛詞、贅語都省掉，讓每條唸起來的長度盡量貼近它的時間軸長度。
數學/專有名詞照原意，但句型要短。

另外，因為是給 TTS 朗讀，所有專有名詞、數學函數與縮寫都要展開成「完整、可直接唸出來」的
英文單字，不可保留縮寫或符號，例如：cos → cosine、sin → sine、tan → tangent、
sec → secant、csc → cosecant、cot → cotangent、ln → natural log、log → log、
lim → limit、max → maximum、min → minimum。其它類似的縮寫一律比照辦理，務必輸出 TTS
能正確發音的完整字詞。
```

Swap 英文 for the actual target language when it isn't English.

**Why merge-before-translate matters for dub:** merging first also hands the LLM whole
sentences instead of fragments — better translation quality *and* naturally shorter,
TTS-friendlier lines, on top of cutting the number of TTS `generate()`/API calls.

## Sanitizing the SRT

`breeze-asr dub` loads `--srt` via SwiftSubtitles (`Subtitles(fileURL:)`), a **strict
line-state machine**: blank → position(int) → timestamp (`\s-->\s`, end-minutes must be 2
digits) → text-lines → blank. It fails the **whole file** on the first malformed block.
Transcribe-side SRT (written by SwiftSubtitles itself) is always fine; **LLM/opencode
output is not** — two failure modes seen in practice:

1. A malformed arrow, e.g. `00:30:31,640 -- 00:31:06,040` (missing `>`). `srt_tool.py`'s
   parser anchors on `-->` and silently absorbs the bad line + its text into the *previous*
   cue, leaking a fake block that SwiftSubtitles then chokes on.
2. A stray embedded newline inside a cue's text, written through verbatim.

**`srt_tool.py validate` does NOT catch failure mode 1.** It only checks that the file
parses to a non-zero cue count (`cmd_validate` in `srt_tool.py`) — an absorbed block just
produces one fewer cue than expected, which still "validates". The real defense against
silent absorption is the **raw cue-count comparison before reattach**, already covered in
workflow step 4: `srt_tool.py count corrected.srt` must equal
`srt_tool.py count translated_llm.srt`. Do that check first; only once counts match does
`validate` below add any real assurance (mainly for hand-edited/manually-fixed files).

Before running `breeze-asr dub`:
```bash
# a) fix any "HH:MM:SS,mmm -- HH:MM:SS,mmm" arrows to "-->"
# b) flatten every cue's text to a single line (" ".join(text.split()))
# c) drop empty cues (dub skips them regardless)
# d) make sure the file ends with a trailing blank line
python3 /Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI/.claude/skills/breeze-asr-subtitle/scripts/srt_tool.py validate "<workdir>/translated.srt"
```
Do this *before* kicking off a ~20+ minute synth run, not after it fails partway through.

## Dub options

```
breeze-asr dub <video> --srt <translated.srt> [options]

TTS ENGINE
  --tts <cloud|local>      Force the engine (default: cloud edge-tts)
  --voice <id>             Cloud voice id (default: en-US-AndrewMultilingualNeural — natural
                            en-US male). Wrong-language voice = garbled audio; pick one that
                            matches the *target* language, e.g. zh-TW-YunJheNeural (雲哲) for
                            Chinese. Other natural en-US male options: Brian/Guy/Christopher/
                            Roger/Steffan Multilingual — the "Multilingual" variants read
                            non-English words (formulas, names) more naturally.

OPTIONS
  --srt <path>              (required) Translated SRT to voice
  -o, --output <path>       Output video (default: <video>.dubbed.mp4)
  --stretch-video            (default) Natural-speed dub, video freeze-extended at dense
                              cues so audio/video stay locked; output is a little longer.
  --no-stretch-video          Fall back to sequential placement (or pair with --uniform-speed)
  --uniform-speed              One global tempo, every cue anchored to its own SRT start
                              time — zero drift, unchanged video length, but the tightest
                              lines may locally overlap the next cue (reported, not fixed).
  --speed <f>                 Force the global tempo (0.5–3.0)
  --sw-encode                  (stretch-video only) libx264 instead of the default
                              VideoToolbox hardware encoder — slower, marginally higher
                              quality. Other modes always stream-copy video (-c:v copy).
  --no-trim-silence            Keep indextts2/edge-tts leading/trailing clip silence
                              (default: trim — tighter onset sync, less speed-up needed)
  --keep-original <vol>        Keep original audio under the dub at this volume (0 = replace)
  --wav-dir <dir>               Reuse already-generated clips in <dir>, skip TTS entirely
  --max-speedup <f>              (sequential mode only) max atempo to fit a clip into its slot

CLONING (opt-in, switches engine to local indextts2)
  --clone                      Clone the original speaker
  --ref <wav>                  Explicit voice reference (implies --clone)
  --ref-start / --ref-duration  Tune the auto-extracted reference clip (default: first
                              cue's start, 15s)
  --indextts2 <path> / --model <dir> / --preproc-dir <dir>   Override sibling-repo paths
  --steps <n>                   Diffusion steps per cue, 1–100 (default 20; engine default
                              is 25 — fewer = faster, slightly lower quality)
```

`breeze-asr dub --help` is the source of truth if this drifts.

### Timeline mode — which to pick

Priority order (matches how the user actually wants lecture dubs to behave):

1. **`--stretch-video`** (default) — keeps the dub at natural speed and extends the video
   at dense cues instead of speeding up speech or letting the dub drift. Preferred for
   lecture content where pacing matters. **Cost caveat:** re-encodes the whole video
   (VideoToolbox by default — minutes, not tens of minutes, on a long 1080p60 clip; `--sw-encode`
   is slower but marginally higher quality).
2. Failing that, shorten the translation (the dub-specific translation prompt already
   asks for this — terse, time-budgeted lines).
3. Only as a last resort, raise the global tempo (`--speed`).

`--uniform-speed` (one global atempo, no re-encode) is the audio-only alternative when a
re-encode isn't wanted, at the cost of possible local overlap on the tightest lines.

## Voice cloning (opt-in)

`--clone`/`--ref` switches the engine to the local **`indextts2-mlx`** sibling repo instead
of cloud edge-tts, and clones the original speaker's voice:

- Binary: `../indextts2-mlx/.build/xcode/Build/Products/Debug/indextts2` — build with
  `./build.sh Debug` in that repo (needs Xcode/Metal; plain `swift build` can't compile MLX).
- Model + preproc: `../indextts2-mlx/models/mlx-indextts2-standard-8bit` and
  `../indextts2-mlx/models/preprocessing`. `DubbingService` passes these as absolute paths
  and sets the subprocess CWD to the repo root, so relative sibling-repo layout "just works"
  from this repo's directory.
- Voice reference: by default extracted straight from the source video (mono 24 kHz clip
  starting at the first cue, 15s) — no external ref.wav needed unless `--ref` overrides it.
- **Cheap iteration:** synthesis (~5s/cue with local indextts2) dominates runtime. Generate
  clips once into a persistent dir, then re-run with `--wav-dir <dir>` to re-tune the
  timeline/tempo without re-synthesising. A normal run deletes its temp clip dir on success.
- Cloud edge-tts has no equivalent quality-vs-speed knob beyond `--voice`; cloning's
  `--steps` is the analogous lever there.

## Long runs need caffeinate

Long `breeze-asr dub` runs (a full-length lecture ≈ tens of minutes of TTS) have been
observed **killed partway with no error in the log** (once at 9/285 cues, once at 62/285).
Root cause: macOS idle/deep-idle sleep freezes the detached background process while the
user is away; the harness then reports it as killed. Tell-tale: stderr stops, wall-clock
then jumps ~tens of minutes, then a `Wake ... due to UserActivity` event on return.

**Fix:** always wrap non-trivial dub runs:
```bash
caffeinate -dimsu breeze-asr dub "<input>" --srt "<translated>.srt" --voice <id> -o "<out>.mp4"
```
`-dimsu` holds PreventSystemSleep + PreventUserIdleSystemSleep + PreventUserIdleDisplaySleep
for the whole child-process lifetime (verify with `pmset -g assertions` → should show
caffeinate "asserting on behalf of …/breeze-asr"). Works on AC power (these runs are). Does
**not** survive a lid-close/clamshell sleep without an external display — that's a real stop,
not an idle-sleep false kill.

## Troubleshooting

- **Whole synth run fails after 20+ minutes with a parse error**: the SRT wasn't sanitized
  first — see [Sanitizing the SRT](#sanitizing-the-srt). Always run the count comparison
  (workflow step 4) *and* `srt_tool.py validate` before a long run, not after — `validate`
  alone misses a silently-absorbed cue.
- **Garbled / wrong-language-sounding audio**: `--voice` doesn't match the target language
  (a zh-TW voice reading English, or vice-versa).
- **Dub sounds too fast / lines overlap**: default `--stretch-video` should prevent this;
  if `--uniform-speed` or `--speed` was used instead, tight cues will locally overlap or
  speed up — either accept it, shorten the translation, or switch back to `--stretch-video`.
- **Background dub job reported "killed" with no error**: see
  [Long runs need caffeinate](#long-runs-need-caffeinate).
- **Re-running to tweak just the timeline/tempo**: use `--wav-dir <dir>` from a prior run
  instead of re-synthesising from scratch (works for both cloud and clone engines).
- **Cloning path can't find indextts2 binary/model**: confirm the `../indextts2-mlx/`
  sibling repo exists and is built (`./build.sh Debug`), or override with `--indextts2` /
  `--model`.
- General breeze-asr CLI issues (model cache, tokenizer TCC error, first-run ANE cold
  compile) → breeze-asr-subtitle skill's
  [REFERENCE.md](../breeze-asr-subtitle/REFERENCE.md#troubleshooting).
