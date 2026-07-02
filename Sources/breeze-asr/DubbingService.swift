import Foundation
import SwiftSubtitles
import SwiftEdgeTTS

/// Generates a time-aligned English dub from a translated SRT and muxes it back into
/// the source video. Per-cue speech is synthesised by the external `indextts2` CLI
/// (../indextts2-mlx); this service owns the *timeline correctness*: each clip is placed
/// at its cue's start time and, when the synthesised speech is longer than its subtitle
/// slot, sped up (atempo) to fit — up to a cap — so dubs do not bleed across cues.
struct DubbingService {
    struct Config {
        var indexTTSBinary: URL
        var modelDir: URL
        var refWav: URL?                // explicit voice reference; nil = extract one from the video
        var refStart: TimeInterval?     // start of the auto-extracted reference clip; nil = first cue
        var refDuration: TimeInterval   // length of the auto-extracted reference clip
        var preprocDir: URL?
        var diffusionSteps: Int         // indextts2 diffusion steps; fewer = faster, slightly lower quality
        var maxSpeedup: Double          // atempo cap when fitting a clip into its slot
        var keepOriginalVolume: Double  // 0 = replace audio; >0 = mix original under the dub
        var reuseWavDir: URL?           // skip TTS and reuse clips already in this dir
        var uniformSpeed: Bool          // one global tempo for the whole video, cues anchored absolutely
        var globalTempo: Double?        // explicit uniform tempo; nil = auto-fit to the video length
        var trimSilence: Bool           // strip indextts2's leading/trailing silence before placing
        var stretchVideo: Bool          // freeze/extend the video at dense cues so natural-speed dub fits
        var ttsEngine: TTSEngine        // .cloud (edge-tts, fixed natural voice) or .local (indextts2 clone)
        var cloudVoice: String          // edge-tts voice id used by the cloud engine
        var quiet: Bool
    }

    /// One subtitle cue paired with its synthesised clip and the timing decision made for it.
    /// Clips are placed sequentially (never overlapping): `placedStart` is the cue's start
    /// pushed later when the previous clip has not finished. `budget` is the room before the
    /// next cue that the clip is sped up to fit into.
    struct Placement {
        let position: Int
        let desiredStart: TimeInterval // cue start in the SRT
        let placedStart: TimeInterval  // actual start after anti-overlap shifting
        let budget: TimeInterval       // room until the next cue's start
        let rawDuration: TimeInterval  // synthesised clip length, natural rate
        let tempo: Double              // applied atempo (>= 1.0)
        var fittedDuration: TimeInterval { rawDuration / tempo }
        var endsAt: TimeInterval { placedStart + fittedDuration }
        var drift: TimeInterval { placedStart - desiredStart }  // how far behind the cue we are
        let wav: URL
    }

    let ffmpeg: FFmpegService
    let config: Config

    /// Full pipeline: SRT → per-cue clips → aligned full-length dub track → muxed video.
    func dub(srt srtURL: URL, video videoURL: URL, output outputURL: URL) async throws {
        let subtitles = try Subtitles(fileURL: srtURL, encoding: .utf8)
        let cues = subtitles.cues.filter { $0.isValidTime }
        guard !cues.isEmpty else { throw CLIError("No valid cues in \(srtURL.path)") }

        let videoDuration = try await ffmpeg.getVideoDuration(url: videoURL)

        let srtStem = srtURL.deletingPathExtension().lastPathComponent

        // 1. Synthesise (or reuse) one clip per cue, named <stem>_<NNN>.wav so both engines and
        //    the reuse path feed identical files into every downstream stage.
        let clipDir: URL
        if let reuse = config.reuseWavDir {
            clipDir = reuse
            log("Reusing clips in \(reuse.path)")
        } else {
            clipDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("breeze-dub-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
            switch config.ttsEngine {
            case .cloud:
                // Cloud TTS (edge-tts): a fixed, natural neural voice — no cloning, so nothing is
                // extracted from the video and indextts2 need not be installed.
                try await synthesiseCloud(cues: cues, srtStem: srtStem, into: clipDir)
            case .local:
                // Local TTS (indextts2): clone the original speaker. An explicit --ref wins;
                // otherwise pull a reference clip straight out of the source video's audio.
                let ref = try await resolveReference(cues: cues, video: videoURL,
                                                     videoDuration: videoDuration, into: clipDir)
                try await synthesise(srt: srtURL, ref: ref, into: clipDir)
            }
        }

        // 2. Gather every cue that has a clip, with its synthesised length, in start order.
        //    indextts2 pads each clip with ~0.3–0.4s of leading/trailing silence; left in, that
        //    both inflates the length (forcing a faster global tempo) and delays the onset (the
        //    speech starts late relative to the cue). Trim it first so durations and anchoring
        //    reflect actual speech. Trimmed copies go to a scratch dir, never the (possibly
        //    reused) clip dir.
        let ordered = cues.sorted { $0.startTimeInSeconds < $1.startTimeInSeconds }
        let trimDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("breeze-dub-trim-\(UUID().uuidString)")
        if config.trimSilence {
            try FileManager.default.createDirectory(at: trimDir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: trimDir) }

        var clips: [(position: Int, start: TimeInterval, raw: TimeInterval, wav: URL)] = []
        for cue in ordered {
            guard let position = cue.position else { continue }
            let wav = clipDir.appendingPathComponent(String(format: "%@_%03d.wav", srtStem, position))
            guard FileManager.default.fileExists(atPath: wav.path) else {
                log("  ⚠️  cue \(position): no clip (\(wav.lastPathComponent)) — skipping")
                continue
            }
            var clipURL = wav
            if config.trimSilence {
                clipURL = trimDir.appendingPathComponent(wav.lastPathComponent)
                try await trimSilence(from: wav, to: clipURL)
            }
            let raw = try await ffmpeg.getVideoDuration(url: clipURL)
            clips.append((position, cue.startTimeInSeconds, raw, clipURL))
        }
        guard !clips.isEmpty else { throw CLIError("No clips were generated — nothing to mux.") }

        // Elastic-timeline mode: keep the dub at a single natural speed and instead stretch the
        // video (freeze the last frame) at cues whose speech overruns, so audio and video stay
        // locked together and nothing overlaps. Handled on its own path and returns.
        if config.stretchVideo {
            try await dubWithStretchedVideo(clips: clips, videoURL: videoURL,
                                            videoDuration: videoDuration, clipDir: clipDir,
                                            output: outputURL)
            return
        }

        // 3. Decide where each clip goes and how fast it plays.
        var placements: [Placement] = []
        if config.uniformSpeed {
            // Uniform mode: one global tempo for the whole video, every cue anchored at its own
            // SRT start (absolute → zero cumulative drift, speech rate constant throughout).
            // Auto tempo makes the total speech fit the video length; the cost is that the
            // tightest cues overlap the next cue locally (non-accumulating, reported below).
            let totalRaw = clips.reduce(0) { $0 + $1.raw }
            let tempo = config.globalTempo ?? max(totalRaw / max(videoDuration, 0.01), 1.0)
            log("Uniform speed: global tempo ×\(fmt(tempo)) "
                + "(\(config.globalTempo == nil ? "auto-fit" : "explicit"); total speech \(fmt(totalRaw))s / video \(fmt(videoDuration))s).")
            for (i, c) in clips.enumerated() {
                let nextStart = i + 1 < clips.count ? clips[i + 1].start : videoDuration
                placements.append(Placement(
                    position: c.position,
                    desiredStart: c.start,
                    placedStart: c.start,                       // absolute anchor, no drift
                    budget: max(nextStart - c.start, 0.05),
                    rawDuration: c.raw,
                    tempo: tempo,
                    wav: c.wav
                ))
            }
        } else {
            // Sequential anti-overlap mode: each clip starts no earlier than its cue and no
            // earlier than the previous clip's end, sped up (capped) to fit the room before the
            // next cue — never overlaps, but speech rate varies and timing drifts when English
            // runs longer than the source.
            var cursor: TimeInterval = 0
            for (i, c) in clips.enumerated() {
                let placedStart = max(c.start, cursor)
                let nextStart = i + 1 < clips.count ? clips[i + 1].start : videoDuration
                let budget = max(nextStart - placedStart, 0.05)
                let tempo = c.raw > budget ? max(min(c.raw / budget, config.maxSpeedup), 1.0) : 1.0
                let p = Placement(
                    position: c.position,
                    desiredStart: c.start,
                    placedStart: placedStart,
                    budget: budget,
                    rawDuration: c.raw,
                    tempo: tempo,
                    wav: c.wav
                )
                placements.append(p)
                cursor = p.endsAt
            }
        }

        reportTimeline(placements, videoDuration: videoDuration)

        // 3. Build the aligned, full-length dub track.
        let dubTrack = clipDir.appendingPathComponent("dubtrack.wav")
        try await buildDubTrack(placements, totalDuration: videoDuration, output: dubTrack)

        // 4. Verify the assembled track length matches the video before muxing.
        let trackDuration = try await ffmpeg.getVideoDuration(url: dubTrack)
        if abs(trackDuration - videoDuration) > 0.5 {
            log("  ⚠️  dub track (\(fmt(trackDuration))s) differs from video (\(fmt(videoDuration))s)")
        } else {
            log("  dub track length \(fmt(trackDuration))s ≈ video \(fmt(videoDuration))s ✓")
        }

        // 5. Mux into the video.
        try await mux(video: videoURL, dubTrack: dubTrack, output: outputURL)

        if config.reuseWavDir == nil {
            try? FileManager.default.removeItem(at: clipDir)
        } else {
            try? FileManager.default.removeItem(at: dubTrack)
        }
    }

    // MARK: - TTS

    /// Resolve the voice reference indextts2 clones. An explicit `--ref` is used as-is; with none,
    /// extract a short clip of the original speaker straight from the source video (default start:
    /// the first cue, so we land on actual speech, not leading titles/silence). The extracted clip
    /// lands in `dir` (the fresh per-run clip dir) and is cleaned up with it.
    private func resolveReference(cues: [Subtitles.Cue], video: URL,
                                  videoDuration: TimeInterval, into dir: URL) async throws -> URL {
        if let provided = config.refWav {
            guard FileManager.default.fileExists(atPath: provided.path) else {
                throw CLIError("Voice reference not found: \(provided.path)")
            }
            return provided
        }

        let firstCue = cues.map(\.startTimeInSeconds).min() ?? 0
        let start = max(config.refStart ?? firstCue, 0)
        let remaining = max(videoDuration - start, 0.5)
        let duration = min(config.refDuration, remaining)
        guard duration >= 0.5 else {
            throw CLIError("Cannot extract a voice reference: only \(fmt(remaining))s of audio after \(fmt(start))s. Pass --ref <wav> or adjust --ref-start.")
        }
        let out = dir.appendingPathComponent("ref-from-video.wav")
        log("Extracting voice reference from video (\(fmt(start))s +\(fmt(duration))s)…")
        try await ffmpeg.extractReferenceClip(from: video, to: out, start: start, duration: duration)
        return out
    }

    private func synthesise(srt srtURL: URL, ref: URL, into dir: URL) async throws {
        guard FileManager.default.fileExists(atPath: config.indexTTSBinary.path) else {
            throw CLIError("indextts2 binary not found: \(config.indexTTSBinary.path)\n  Build it (../indextts2-mlx: ./build.sh Debug) or pass --indextts2 <path>.")
        }
        log("Synthesising dub clips with indextts2…")
        // indextts2 defaults --model and --preproc-dir to paths *relative to its own CWD*
        // (`models/…`). Launched as a subprocess our CWD is breeze-asr's, so pass every path
        // absolutely. The preprocessing weights sit beside the model dir (`models/preprocessing`)
        // in the standard repo layout; derive that if the caller did not override it.
        let preproc = config.preprocDir
            ?? config.modelDir.deletingLastPathComponent().appendingPathComponent("preprocessing")
        let args = [
            "--model", config.modelDir.path,
            "--preproc-dir", preproc.path,
            "--ref", ref.path,
            "--srt", srtURL.path,
            "--out", dir.path,
            // Diffusion steps dominate per-cue synthesis time; fewer steps trade a little
            // quality for a near-linear speedup. The engine default is 25.
            "--steps", String(config.diffusionSteps)
        ]

        let process = Process()
        process.executableURL = config.indexTTSBinary
        process.arguments = args
        // Run from the indextts2 repo root (grandparent of the model dir) so any remaining
        // relative lookups inside indextts2 resolve. Only set it if it exists.
        let repoRoot = config.modelDir.deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: repoRoot.path) {
            process.currentDirectoryURL = repoRoot
        }
        // indextts2 logs progress to stderr; pass it through (unless quiet) so the user
        // sees per-segment synthesis. stdout is left attached too — it prints nothing useful.
        if config.quiet {
            process.standardError = Pipe()
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError("indextts2 exited with status \(process.terminationStatus)")
        }
    }

    // MARK: - Cloud TTS (edge-tts, native)

    /// Synthesise one clip per cue with edge-tts (Microsoft neural voices) via the pure-Swift
    /// SwiftEdgeTTS client — a fixed, natural voice, no cloning, no Python and no external binary.
    /// Each cue is spoken at its natural rate (the timeline stage applies any speed-up) and written
    /// as <stem>_<NNN>.wav (mono 22.05 kHz pcm) so cloud and indextts2 clips are byte-format-
    /// identical from here on. Cloud synthesis needs an internet connection.
    private func synthesiseCloud(cues: [Subtitles.Cue], srtStem: String, into dir: URL) async throws {
        let edge = EdgeTTSService()
        let ordered = cues.sorted { $0.startTimeInSeconds < $1.startTimeInSeconds }
        log("Synthesising \(ordered.count) dub clips with edge-tts (voice \(config.cloudVoice))…")
        var done = 0
        for cue in ordered {
            guard let position = cue.position else { continue }
            // SRT text can span several lines; flatten it to a single spoken string.
            let text = cue.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                log("  ⚠️  cue \(position): empty text — skipping")
                continue
            }
            // edge-tts emits mp3; transcode to the pipeline's wav format so trimming/placement
            // treat cloud and local clips identically.
            let mp3 = dir.appendingPathComponent(String(format: "%@_%03d.mp3", srtStem, position))
            try await synthesiseCue(edge, text: text, out: mp3)
            let wav = dir.appendingPathComponent(String(format: "%@_%03d.wav", srtStem, position))
            try await ffmpeg.run(["-i", mp3.path, "-ar", "22050", "-ac", "1",
                                  "-c:a", "pcm_s16le", "-y", wav.path])
            try? FileManager.default.removeItem(at: mp3)
            done += 1
            if !config.quiet {
                FileHandle.standardError.write(Data("\r  [edge-tts] \(done)/\(ordered.count)   ".utf8))
            }
        }
        if !config.quiet { FileHandle.standardError.write(Data("\n".utf8)) }
        guard done > 0 else { throw CLIError("edge-tts produced no clips (all cues empty?).") }
    }

    /// Synthesise a single cue via SwiftEdgeTTS, writing an mp3 to `out`. The Microsoft endpoint
    /// intermittently returns no audio (and occasionally rate-limits); left unhandled, one such
    /// blip aborts a whole multi-hundred-cue dub. So retry a few times with a short backoff, and
    /// treat a zero-byte result as a failure too.
    private func synthesiseCue(_ edge: EdgeTTSService, text: String, out: URL) async throws {
        let maxAttempts = 4
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                _ = try await edge.synthesize(text: text, voice: config.cloudVoice, outputURL: out)
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)??.intValue ?? 0
                if size > 0 { return }
                lastError = CLIError("edge-tts returned an empty audio file")
            } catch {
                lastError = error
            }
            try? FileManager.default.removeItem(at: out)
            if attempt < maxAttempts {
                log("  ⚠️  edge-tts attempt \(attempt)/\(maxAttempts) failed, retrying…")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
        throw CLIError("edge-tts failed after \(maxAttempts) attempts: "
            + "\(lastError.map { String(describing: $0) } ?? "unknown error")\n"
            + "  (Cloud TTS needs an internet connection; the Microsoft endpoint also rate-limits — "
            + "if this persists, retry later.)")
    }

    // MARK: - Elastic timeline (stretch video to fit a natural-speed dub)

    /// One slice of the rebuilt timeline: the original video window `[origStart, origEnd)` held
    /// for `targetDur` (≥ the window — the surplus is a frozen tail), optionally carrying a dub.
    private struct Segment {
        let origStart: TimeInterval
        let origEnd: TimeInterval
        let targetDur: TimeInterval
        let dub: (wav: URL, position: Int, rawDuration: TimeInterval)?
        var window: TimeInterval { origEnd - origStart }
        var freeze: TimeInterval { max(targetDur - window, 0) }
    }

    /// Dub by stretching the video instead of compressing the audio: the dub plays at one
    /// natural speed and each cue's video window is frozen-extended just enough to contain it,
    /// so audio and video stay in lockstep and never overlap. The output video is a little longer
    /// than the source, with brief freezes at the densest moments.
    private func dubWithStretchedVideo(clips: [(position: Int, start: TimeInterval, raw: TimeInterval, wav: URL)],
                                       videoURL: URL, videoDuration: TimeInterval,
                                       clipDir: URL, output: URL) async throws {
        let tempo = max(config.globalTempo ?? 1.0, 0.5)

        // Tile [0, videoDuration] into segments: an optional leading gap with no dub, then one
        // per cue running to the next cue's start (the last to the video end).
        var segments: [Segment] = []
        if clips[0].start > 0.05 {
            segments.append(Segment(origStart: 0, origEnd: clips[0].start,
                                    targetDur: clips[0].start, dub: nil))
        }
        for (i, c) in clips.enumerated() {
            let origEnd = i + 1 < clips.count ? clips[i + 1].start : videoDuration
            let window = max(origEnd - c.start, 0.01)
            let dubDur = c.raw / tempo
            segments.append(Segment(origStart: c.start, origEnd: origEnd,
                                    targetDur: max(window, dubDur),
                                    dub: (c.wav, c.position, c.raw)))
        }

        // New cumulative starts; audio placements anchor each dub at its segment start.
        var placements: [Placement] = []
        var cursor: TimeInterval = 0
        for s in segments {
            if let d = s.dub {
                placements.append(Placement(position: d.position, desiredStart: s.origStart,
                                            placedStart: cursor, budget: s.targetDur,
                                            rawDuration: d.rawDuration, tempo: tempo, wav: d.wav))
            }
            cursor += s.targetDur
        }
        let newTotal = cursor

        let frozen = segments.filter { $0.freeze > 0.01 }
        let maxFreeze = segments.map(\.freeze).max() ?? 0
        log("Stretch video: dub at ×\(fmt(tempo)) (natural), \(frozen.count) segments extended; "
            + "video \(fmt(videoDuration))s → \(fmt(newTotal))s (+\(fmt(newTotal - videoDuration))s), worst freeze \(fmt(maxFreeze))s.")

        // Build the stretched (silent) video, then the natural-speed dub track, then mux.
        let stretched = clipDir.appendingPathComponent("stretched.mp4")
        let dubTrack = clipDir.appendingPathComponent("dubtrack.wav")
        try await buildStretchedVideo(segments, source: videoURL, output: stretched)
        try await buildDubTrack(placements, totalDuration: newTotal, output: dubTrack)

        let trackDuration = try await ffmpeg.getVideoDuration(url: dubTrack)
        let videoOut = try await ffmpeg.getVideoDuration(url: stretched)
        log("  stretched video \(fmt(videoOut))s, dub track \(fmt(trackDuration))s "
            + (abs(videoOut - trackDuration) < 0.3 ? "(aligned ✓)" : "(⚠️ mismatch)"))

        try await mux(video: stretched, dubTrack: dubTrack, output: output)

        try? FileManager.default.removeItem(at: stretched)
        try? FileManager.default.removeItem(at: dubTrack)
        if config.reuseWavDir == nil { try? FileManager.default.removeItem(at: clipDir) }
    }

    /// Re-encode the source into one video stream where each segment is its original window with
    /// a frozen-frame tail (`tpad`) appended to reach its target duration, then concatenated.
    /// One `filter_complex` (split → trim/setpts/tpad per segment → concat); video only.
    private func buildStretchedVideo(_ segments: [Segment], source: URL, output: URL) async throws {
        let n = segments.count
        var parts: [String] = []
        let splitOuts = (0..<n).map { "[s\($0)]" }.joined()
        parts.append("[0:v]split=\(n)\(splitOuts)")
        var concatIns = ""
        for (i, seg) in segments.enumerated() {
            var chain = "[s\(i)]trim=start=\(String(format: "%.3f", seg.origStart)):end=\(String(format: "%.3f", seg.origEnd)),setpts=PTS-STARTPTS"
            if seg.freeze > 0.01 {
                chain += ",tpad=stop_mode=clone:stop_duration=\(String(format: "%.3f", seg.freeze))"
            }
            chain += "[p\(i)]"
            parts.append(chain)
            concatIns += "[p\(i)]"
        }
        parts.append("\(concatIns)concat=n=\(n):v=1:a=0[v]")
        let filter = parts.joined(separator: ";")

        log("Assembling stretched video (\(n) segments)…")
        try await ffmpeg.run([
            "-i", source.path,
            "-filter_complex", filter,
            "-map", "[v]", "-an",
            "-r", "60", "-fps_mode", "cfr",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
            "-y", output.path
        ])
    }

    // MARK: - Clip preprocessing

    /// Strip leading/trailing silence (keeping internal pauses) from a synthesised clip via the
    /// standard reverse-trim-reverse `silenceremove` idiom. A small `start_silence` margin keeps
    /// word onsets from being clipped. Output stays mono 22.05 kHz pcm to match the clips.
    private func trimSilence(from input: URL, to output: URL) async throws {
        let trim = "silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.03,"
            + "areverse,"
            + "silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.03,"
            + "areverse"
        try await ffmpeg.run([
            "-i", input.path,
            "-af", trim,
            "-ar", "22050", "-ac", "1", "-c:a", "pcm_s16le",
            "-y", output.path
        ])
    }

    // MARK: - Timeline assembly

    /// ffmpeg's single `atempo` accepts 0.5–2.0; chain two filters for factors up to ×4 so a
    /// uniform/global tempo above 2.0 still works. Returns a trailing-comma-terminated filter
    /// fragment (or empty for ~1.0).
    static func atempoChain(_ tempo: Double) -> String {
        guard tempo > 1.0001 || tempo < 0.9999 else { return "" }
        if tempo <= 2.0 {
            return "atempo=\(String(format: "%.6f", tempo)),"
        }
        let first = 2.0
        let second = min(tempo / first, 2.0)
        return "atempo=\(String(format: "%.6f", first)),atempo=\(String(format: "%.6f", second)),"
    }

    /// Builds one full-length mono track: each clip is `atempo`-fitted, delayed to its
    /// (anti-overlap) placed start, summed with `amix` (normalize=0 keeps original loudness),
    /// then padded/trimmed to the exact video duration so the muxed audio spans the whole film.
    /// Placements never overlap, so the `amix` sum reduces to a simple timeline assembly.
    private func buildDubTrack(_ placements: [Placement], totalDuration: TimeInterval, output: URL) async throws {
        var inputs: [String] = []
        var filters: [String] = []
        var labels: [String] = []

        for (i, p) in placements.enumerated() {
            inputs += ["-i", p.wav.path]
            let delayMs = Int((p.placedStart * 1000).rounded())
            var chain = "[\(i):a]"
            chain += Self.atempoChain(p.tempo)
            chain += "adelay=\(delayMs):all=1[a\(i)]"
            filters.append(chain)
            labels.append("[a\(i)]")
        }

        let durMs = Int((totalDuration * 1000).rounded())
        let mix = labels.joined()
            + "amix=inputs=\(placements.count):normalize=0:dropout_transition=0,"
            + "apad,atrim=end=\(String(format: "%.3f", totalDuration)),asetpts=N/SR/TB[out]"
        let filterComplex = (filters + [mix]).joined(separator: ";")
        _ = durMs  // duration enforced via atrim above

        log("Assembling dub track (\(placements.count) clips)…")
        let args = inputs + [
            "-filter_complex", filterComplex,
            "-map", "[out]",
            "-ac", "1", "-ar", "22050",
            "-c:a", "pcm_s16le",
            "-y", output.path
        ]
        try await ffmpeg.run(args)
    }

    private func mux(video: URL, dubTrack: URL, output: URL) async throws {
        log("Muxing dub into video…")
        var args = ["-i", video.path, "-i", dubTrack.path]
        if config.keepOriginalVolume > 0 {
            // Duck the original speech under the dub instead of replacing it.
            let fc = "[0:a]volume=\(String(format: "%.3f", config.keepOriginalVolume))[orig];"
                + "[orig][1:a]amix=inputs=2:normalize=0:dropout_transition=0[a]"
            args += ["-filter_complex", fc, "-map", "0:v:0", "-map", "[a]"]
        } else {
            // Replace the audio entirely with the dub.
            args += ["-map", "0:v:0", "-map", "1:a:0"]
        }
        args += [
            "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k",
            "-shortest",
            "-y", output.path
        ]
        try await ffmpeg.run(args)
    }

    // MARK: - Reporting

    private func reportTimeline(_ placements: [Placement], videoDuration: TimeInterval) {
        guard !config.quiet else { return }
        if config.uniformSpeed {
            // Uniform mode: no drift by construction; the artifact is local overlap where a
            // cue's (uniformly-sped) clip runs past the next cue's start.
            let overlapping = placements.filter { $0.fittedDuration - $0.budget > 0.05 }
            let maxOver = placements.map { $0.fittedDuration - $0.budget }.max() ?? 0
            log("Timeline (uniform): \(placements.count) cues anchored to their starts, zero drift; "
                + "\(overlapping.count) overlap the next cue, worst +\(fmt(max(maxOver, 0)))s.")
            for p in overlapping {
                log(String(format: "  ⚠️  cue %d @ %@s: %.2fs clip ×%.2f → %.2fs into %.2fs gap (consider shortening this line)",
                           p.position, fmt(p.desiredStart), p.rawDuration, p.tempo, p.fittedDuration, p.budget))
            }
        } else {
            let sped = placements.filter { $0.tempo > 1.0001 }
            let drifting = placements.filter { $0.drift > 0.25 }   // started noticeably late
            let maxDrift = placements.map(\.drift).max() ?? 0
            log("Timeline: \(placements.count) cues, \(sped.count) sped up (cap ×\(fmt(config.maxSpeedup))), "
                + "\(drifting.count) drift >0.25s, max drift \(fmt(maxDrift))s.")
            for p in drifting {
                log(String(format: "  ⚠️  cue %d: cue@%@s but placed@%@s (+%.2fs late) — %.2fs speech ×%.2f → %.2fs",
                           p.position, fmt(p.desiredStart), fmt(p.placedStart), p.drift,
                           p.rawDuration, p.tempo, p.fittedDuration))
            }
        }
        let endsAt = placements.map(\.endsAt).max() ?? 0
        if endsAt > videoDuration + 0.25 {
            log(String(format: "  ⚠️  dub runs %.2fs past the video end (%.2fs); the tail will be trimmed.",
                       endsAt - videoDuration, videoDuration))
        }
    }

    private func log(_ message: String) {
        guard !config.quiet else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func fmt(_ t: TimeInterval) -> String { String(format: "%.2f", t) }
}
