#!/usr/bin/env python3
"""SRT safety net for the breeze-asr-subtitle skill.

opencode does the LLM correction/translation but must never alter indices or
timings. `reattach` rebuilds an SRT using the ORIGINAL file's cue boundaries and
timestamps as the source of truth, taking only the *text* from the LLM output
(aligned by position). This mirrors SubtitleService.reattachOriginalTimestamps
from the original ANEMLBreezeASR app.

Usage:
  srt_tool.py count <file.srt>
  srt_tool.py validate <file.srt>
  srt_tool.py reattach <original.srt> <llm.srt> <output.srt> [--fallback keep|empty]
  srt_tool.py merge <in.srt> <out.srt> [--max-gap S] [--max-dur S] [--max-chars N]

  --fallback keep   (default) mismatched cues fall back to the original text
                    — use for same-language correction.
  --fallback empty  mismatched cues become empty — use for translation, so the
                    output never leaks source-language text.

  merge             Coalesce adjacent cues into longer ones (combining their time
                    ranges) so a DUBBING pass synthesises far fewer, longer
                    utterances — IndexTTS-2 cost is dominated by the number of
                    generate() calls, not total audio. Use only on the dubbing
                    branch; plain reading subtitles want the fine-grained cues.
  --max-gap S       don't merge across a silence gap longer than S sec (default 1.0)
  --max-dur S       cap a merged cue's span at S sec (default 12.0)
  --max-chars N     cap a merged cue's text length at N chars (default 200)
"""
import re
import sys

_TS = re.compile(
    r"(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)"
)


def strip_fences(text):
    """Drop a leading ```... fence and trailing ``` an LLM may have added."""
    s = text.strip()
    if s.startswith("```"):
        nl = s.find("\n")
        s = s[nl + 1:] if nl != -1 else ""
    if s.endswith("```"):
        s = s[:-3]
    return s.strip()


def parse(text):
    """Parse SRT text into a list of cues: {start, end, text}.

    Cues are split on the timestamp lines themselves, NOT on blank lines, so
    output that omits the blank separator between entries still parses 1:1.
    (Some LLMs emit `index / timestamp / text` back-to-back with no blank
    line; the old blank-line split collapsed such a file into one giant cue.)
    """
    lines = strip_fences(text).splitlines()
    # Every timestamp line is exactly one cue — the reliable anchor.
    ts_pos = [i for i, ln in enumerate(lines) if _TS.search(ln)]
    cues = []
    for k, p in enumerate(ts_pos):
        m = _TS.search(lines[p])
        start, end = lines[p][m.start():m.end()].split("-->")
        # Text runs from just after this timestamp to the next cue. The line
        # directly above the next timestamp is that cue's index — drop it when
        # it's a bare integer (it's not subtitle text). Works whether or not a
        # blank line precedes it.
        if k + 1 < len(ts_pos):
            text_end = ts_pos[k + 1]
            if lines[text_end - 1].strip().isdigit():
                text_end -= 1
        else:
            text_end = len(lines)
        body = "\n".join(lines[p + 1:text_end]).strip()
        cues.append({"start": start.strip(), "end": end.strip(), "text": body})
    return cues


def fmt(cues):
    out = []
    for i, c in enumerate(cues, 1):
        out.append(f"{i}\n{c['start']} --> {c['end']}\n{c['text']}".rstrip())
    return "\n\n".join(out) + "\n"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _ts_to_sec(ts):
    m = re.match(r"(\d+):(\d+):(\d+)[,.](\d+)", ts.strip())
    h, mi, s, ms = (int(x) for x in m.groups())
    return h * 3600 + mi * 60 + s + ms / 1000.0


def cmd_merge(args):
    max_gap, max_dur, max_chars = 1.0, 12.0, 200
    rest = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--max-gap":
            max_gap = float(args[i + 1]); i += 2
        elif a == "--max-dur":
            max_dur = float(args[i + 1]); i += 2
        elif a == "--max-chars":
            max_chars = int(args[i + 1]); i += 2
        else:
            rest.append(a); i += 1
    in_path, out_path = rest[0], rest[1]

    cues = parse(read(in_path))
    merged = []
    for c in cues:
        if not merged:
            merged.append(dict(c))
            continue
        prev = merged[-1]
        gap = _ts_to_sec(c["start"]) - _ts_to_sec(prev["end"])
        span = _ts_to_sec(c["end"]) - _ts_to_sec(prev["start"])
        joined = (prev["text"] + " " + c["text"]).strip()
        if gap <= max_gap and span <= max_dur and len(joined) <= max_chars:
            prev["end"] = c["end"]
            prev["text"] = joined
        else:
            merged.append(dict(c))

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(fmt(merged))
    print(f"in={len(cues)} out={len(merged)}")


def cmd_count(args):
    print(len(parse(read(args[0]))))


def cmd_validate(args):
    cues = parse(read(args[0]))
    if not cues:
        sys.stderr.write("invalid: no cues parsed\n")
        sys.exit(1)
    print(f"valid: {len(cues)} cues")


def cmd_reattach(args):
    fallback = "keep"
    if "--fallback" in args:
        i = args.index("--fallback")
        fallback = args[i + 1]
        args = args[:i] + args[i + 2:]
    original_path, llm_path, out_path = args[0], args[1], args[2]

    original = parse(read(original_path))
    llm = parse(read(llm_path))

    rebuilt = []
    mismatches = 0
    for i, orig in enumerate(original):
        if i < len(llm) and llm[i]["text"].strip():
            text = llm[i]["text"].strip()
        else:
            text = orig["text"] if fallback == "keep" else ""
            mismatches += 1
        rebuilt.append({"start": orig["start"], "end": orig["end"], "text": text})

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(fmt(rebuilt))
    print(f"cues={len(rebuilt)} mismatches={mismatches}")


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        sys.exit(2)
    cmd, rest = sys.argv[1], sys.argv[2:]
    {"count": cmd_count, "validate": cmd_validate, "reattach": cmd_reattach,
     "merge": cmd_merge}.get(
        cmd, lambda _: (sys.stderr.write(__doc__), sys.exit(2))
    )(rest)


if __name__ == "__main__":
    main()
