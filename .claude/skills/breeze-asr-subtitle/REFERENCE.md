# breeze-asr-subtitle — Reference

## CLI: `breeze-asr`

Source: `/Users/chenlu-hung/Documents/Projects/ANEMLBreezeASRCLI` (Swift Package).
Binary: `.build/release/breeze-asr`.

```
breeze-asr <input> [options]

  <input>                 Video or audio file (anything FFmpeg can read)
  -l, --language <code>   Source language (default auto): zh en ja ko es fr de it pt ru ar hi auto
  -o, --output <path>     Output SRT path (default: <input>.srt)
      --model-path <dir>  Use a specific Breeze-ASR-25 model folder
  -q, --quiet             Suppress progress
  -h, --help              Help
```

- **stdout** = the final SRT path (capture this). **stderr** = progress + logs.
- Pipeline: FFmpeg extracts 16 kHz mono WAV → WhisperKit/Breeze-ASR-25 transcribes
  (VAD chunking) → SRT via SwiftSubtitles. No LLM, no burning.
- Model resolution order: `--model-path` → `~/Library/Application Support/ANEMLBreezeASR/HubCache`
  → `~/Library/Application Support/VibeTyping/HubCache` → download from
  `aoiandroid/Breeze-ASR-25_coreml` (~3 GB, only if none cached).

## Dispatching correction to opencode

Use the **dispatch skill** with a self-contained brief (opencode has no access to this
conversation). A plain file task — no git worktree needed.

The core instruction is the user's field-tested opencode prompt. The crucial constraint
是 **「由你直接動手，禁止撰寫程式或呼叫外部 API」** — opencode must do the correction
with its own model, NOT write a script or call an external API. Keep that line verbatim.

```
按照上下文校正這個中文字幕並存成另一個 srt 檔。禁止更動字幕的時間軸。由你直接動手，禁止撰寫程式或呼叫外部 API。

輸入檔：  <workdir>/raw.srt
輸出檔：  <workdir>/corrected.srt

規則：保持完全相同的字幕條目數量與順序，不要合併、拆分、增加或刪除任何條目；
每條的編號與「HH:MM:SS,mmm --> HH:MM:SS,mmm」時間軸原樣保留，只改文字行；
輸出純 SRT，不要加說明或 markdown 程式碼框。
```

Timestamps are re-asserted afterward by `srt_tool.py reattach`, so even if opencode
slips, timing stays correct. What matters is that text stays aligned 1:1 by position.

## Dispatching translation to opencode

Same shape, but translate. Run `reattach` with `--fallback empty` so any unaligned cue
becomes blank rather than leaking source-language text. Core instruction is again the
user's tested prompt (swap 英文 for the actual target language):

```
把這份中文字幕檔翻譯成英文字幕並存成另一個 srt 檔。禁止更動字幕的時間軸。由你直接動手，禁止撰寫程式或呼叫外部 API。

輸入檔：  <workdir>/corrected.srt
輸出檔：  <workdir>/translated.srt

規則：保持完全相同的字幕條目數量與順序，不要合併、拆分、增加或刪除任何條目；
每條的編號與時間軸原樣保留，只改文字行；輸出純 SRT，不要加說明或 markdown 程式碼框。
```

### When the translation is for **dubbing** (TTS voice-over)

If the translated SRT will be fed to `breeze-asr dub` (spoken aloud, not just read), add a
conciseness requirement so each line fits its time slot at a natural speaking rate — the
target language is usually longer than the source, and verbose lines force speed-up,
overlap, or video stretching. Append to the prompt above:

```
這份翻譯會用來做配音（TTS 朗讀），所以每一條請盡量「簡短口語」：在不漏掉重點的前提下，
用最精簡的字數表達，能省的虛詞、贅語都省掉，讓每條唸起來的長度盡量貼近它的時間軸長度。
數學/專有名詞照原意，但句型要短。

另外，因為是給 TTS 朗讀，所有專有名詞、數學函數與縮寫都要展開成「完整、可直接唸出來」的
英文單字，不可保留縮寫或符號，例如：cos → cosine、sin → sine、tan → tangent、
sec → secant、csc → cosecant、cot → cotangent、ln → natural log、log → log、
lim → limit、max → maximum、min → minimum。其它類似的縮寫一律比照辦理，務必輸出 TTS
能正確發音的完整字詞。
```

(Plain reading subtitles don't need this — only dubbing.)

**Coalesce cues before translating for dubbing.** IndexTTS-2's cost is dominated by the
*number* of `generate()` calls, not total audio length, so a dub built from many tiny VAD
cues is far slower than one built from a few long utterances (this is why per-slide
lecture TTS is much faster than per-cue dub). On the **dubbing branch only**, merge the raw
cues into longer ones *before* correction/translation:

```
srt_tool.py merge raw.srt merged.srt          # tune --max-gap/--max-dur/--max-chars
```

Then run the correction/translation prompt against `merged.srt`. Merging first also gives
the LLM whole sentences for context (better translation, naturally longer lines). The dub
is the final artifact, so it does NOT need to reattach to the original fine-grained
timestamps — keep those only for the reading-subtitle branch. Pair this with a lower
`breeze-asr dub --steps <n>` (default 20) for a compounding speedup.

## srt_tool.py

```
srt_tool.py count <file.srt>                 # print cue count
srt_tool.py validate <file.srt>              # exit 1 if it parses to 0 cues
srt_tool.py reattach <orig> <llm> <out> [--fallback keep|empty]
```

`reattach` rebuilds `<out>` from `<orig>`'s indices+timestamps, taking text from `<llm>`
aligned by position. Tolerant of markdown fences, mangled timestamps, and **missing
blank-line separators** between entries in `<llm>` — `parse()` splits on the timestamp
lines, not on blank lines, so a run-together SRT (opencode/DeepSeek often omits the blank
line) still aligns 1:1 instead of collapsing into one cue.
`--fallback keep` (default) → unaligned cues keep original text (correction);
`--fallback empty` → unaligned cues blank (translation). Prints `cues=N mismatches=M`.

## Whole-SRT — do NOT chunk

Send the entire `raw.srt` (or `corrected.srt`) in a single opencode/agy task — do **not**
split it, regardless of length. The full file fits the context window (field-tested on
opencode and agy), and giving the model the whole transcript at once yields better
context-correction and translation than stitching together independently-corrected chunks
(chunk boundaries lose cross-sentence context and risk cue-count drift).

Don't confuse this with the dubbing `merge` step above: that coalesces cues to cut
IndexTTS-2 `generate()` calls, not to fit a context window — it stays on the dubbing
branch only.

## Troubleshooting

- **CLI looks hung at "Loading model…" (can last ~40 min)**: this is *not* an ANE deadlock
  (that old claim was a too-early kill) — compute units default to `.cpuAndNeuralEngine`
  because the NPU beats the GPU for this model on Apple silicon, and it's stable in this
  unsigned CLI. What's actually happening: the **first** ANE run does a one-time cold
  compile of the 1.2 GB encoder (~40 min), then ANECompilerService caches it per bundle-id
  (`breeze-asr`) under `~/Library/Caches/breeze-asr/com.apple.e5rt.e5bundlecache`; later
  loads take ~3 s. That cache is per-bundle-id, so a warm compile from another app (e.g.
  VibeTyping) isn't inherited — only the `.mlmodelc` model files are shared. On a fresh
  machine, after a cache wipe, or if the bundle id changes, expect the ~40 min compile
  again; pass `--compute gpu` for an instant load when a warm ANE cache isn't available.
- **"could not remove corrupted metadata file: config.json.metadata … permission"**: the
  Whisper tokenizer was being written to TCC-protected `~/Documents/huggingface`. The CLI
  pins `tokenizerFolder` to `~/Library/Application Support/ANEMLBreezeASR/HubCache` to
  avoid this. If it recurs, that cache dir may be unwritable.
- **Model re-downloads despite VibeTyping having it**: the cache must match the canonical
  `models/aoiandroid/Breeze-ASR-25_coreml/` layout with a real (>100 MB) AudioEncoder.
- **Empty/garbled transcription**: pass the correct `-l` source language instead of `auto`.
