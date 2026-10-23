import Foundation
import SwiftSubtitles

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
        var compressGaps: Double?       // stretch: fast-forward each cue's leftover silence ×this; nil = off
        var gapPause: TimeInterval      // stretch + compressGaps: pause kept at 1× after each cue's speech
        var fitRateMax: Int?            // cloud: slow sparse cues by up to this % to fill their slot; nil = off
        var burnSubtitles: Bool         // burn the dub's text into the video (needs an ffmpeg with libass)
        var hardwareVideoEncode: Bool   // stretch re-encode: true = VideoToolbox HW (fast), false = libx264
        var ttsEngine: TTSEngine        // .cloud (edge-tts, fixed natural voice) or .local (indextts2 clone)
        var cloudVoice: String          // edge-tts voice id used by the cloud engine
        var edgeTTSBinary: URL?         // python `edge-tts` CLI used by the cloud engine
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
                try await synthesiseCloud(cues: cues, srtStem: srtStem, videoDuration: videoDuration,
                                          into: clipDir)
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
        let texts = Dictionary(cues.compactMap { cue in cue.position.map { ($0, cue.text) } },
                               uniquingKeysWith: { first, _ in first })

        // Elastic-timeline mode: keep the dub at a single natural speed and instead stretch the
        // video (freeze the last frame) at cues whose speech overruns, so audio and video stay
        // locked together and nothing overlaps. Handled on its own path and returns.
        if config.stretchVideo {
            try await dubWithStretchedVideo(clips: clips, texts: texts, srtURL: srtURL, videoURL: videoURL,
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

        // 5. Mux into the video (re-encoding it only to burn subtitles).
        let retimed = try writeSubtitles(placements, texts: texts, totalDuration: videoDuration,
                                         srtURL: srtURL, output: outputURL)
        let burn = config.burnSubtitles ? try burnableCopy(of: retimed) : nil
        defer { if let burn { try? FileManager.default.removeItem(at: burn) } }
        try await mux(video: videoURL, dubTrack: dubTrack, burn: burn, output: outputURL)

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

    // MARK: - Cloud TTS (edge-tts CLI)

    /// Cues synthesised at once. Each edge-tts call is network-bound (~1–2 s), so a few in flight
    /// cut a long dub's TTS time severalfold without tripping the endpoint's rate limit.
    private static let edgeTTSConcurrency = 4

    /// Synthesise one clip per cue with edge-tts (Microsoft neural voices) by running the python
    /// `edge-tts` CLI — a fixed, natural voice, no cloning. The CLI is used instead of a native
    /// Swift client because Microsoft changes the endpoint's request signing without notice
    /// (2026-10: `Sec-MS-GEC` v2 broke SwiftEdgeTTS 1.3.0) and python edge-tts tracks it promptly;
    /// the fix is then just `pip install -U edge-tts`. Each cue is spoken at its natural rate (the
    /// timeline stage applies any speed-up) and written as <stem>_<NNN>.wav (mono 22.05 kHz pcm)
    /// so cloud and indextts2 clips are byte-format-identical from here on. Needs internet.
    ///
    /// With `fitRateMax`, a cue whose natural-rate speech fills less than `fitRateTarget` of its
    /// slot (until the next cue starts) is re-synthesised slower — edge-tts `--rate`, at most
    /// `fitRateMax`% — so speech is spread over the slot instead of rushing then going silent.
    private func synthesiseCloud(cues: [Subtitles.Cue], srtStem: String, videoDuration: TimeInterval,
                                 into dir: URL) async throws {
        guard let binary = config.edgeTTSBinary else { throw CLIError("edge-tts CLI not configured.") }
        let ordered = cues.sorted { $0.startTimeInSeconds < $1.startTimeInSeconds }
        let jobs: [(position: Int, text: String, slot: TimeInterval)] = ordered.enumerated()
            .compactMap { i, cue in
                guard let position = cue.position else { return nil }
                let nextStart = i + 1 < ordered.count ? ordered[i + 1].startTimeInSeconds : videoDuration
                let slot = max(nextStart - cue.startTimeInSeconds, 0.05)
                // SRT text can span several lines; flatten it to a single spoken string.
                let text = cue.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    log("  ⚠️  cue \(position): empty text — skipping")
                    return nil
                }
                return (position, text, slot)
            }
        log("Synthesising \(jobs.count) dub clips with edge-tts (voice \(config.cloudVoice)"
            + (config.fitRateMax.map { ", fitting rate down to -\($0)%" } ?? "") + ")…")
        var done = 0
        var rates: [Int] = []
        func tick(_ rate: Int) {
            done += 1
            rates.append(rate)
            if !config.quiet {
                FileHandle.standardError.write(Data("\r  [edge-tts] \(done)/\(jobs.count)   ".utf8))
            }
        }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for (i, job) in jobs.enumerated() {
                if i >= Self.edgeTTSConcurrency, let rate = try await group.next() {
                    tick(rate)
                }
                group.addTask {
                    let wav = dir.appendingPathComponent(String(format: "%@_%03d.wav", srtStem, job.position))
                    try await synthesiseCloudClip(binary: binary, text: job.text, rate: 0, wav: wav)
                    guard let maxSlow = config.fitRateMax else { return 0 }
                    let speech = try await speechDuration(of: wav)
                    let rate = Self.fittedRate(speech: speech, slot: job.slot, maxSlowdown: maxSlow)
                    if rate < 0 {
                        try await synthesiseCloudClip(binary: binary, text: job.text, rate: rate, wav: wav)
                    }
                    return rate
                }
            }
            while let rate = try await group.next() { tick(rate) }
        }
        if !config.quiet { FileHandle.standardError.write(Data("\n".utf8)) }
        guard done > 0 else { throw CLIError("edge-tts produced no clips (all cues empty?).") }
        if config.fitRateMax != nil {
            let slowed = rates.filter { $0 < 0 }.sorted()
            let median = slowed.isEmpty ? 0 : slowed[slowed.count / 2]
            log("Fit rate: \(slowed.count)/\(rates.count) cues slowed (median \(median)%, "
                + "\(rates.filter { $0 == -(config.fitRateMax ?? 0) }.count) at the -\(config.fitRateMax ?? 0)% cap).")
        }
    }

    /// Share of a cue's slot that `--fit-rate` aims to fill with speech.
    private static let fitRateTarget = 0.9

    /// edge-tts `--rate` percent (≤ 0) that stretches `speech` to `fitRateTarget` of `slot`,
    /// assuming duration scales with 1/(1 + rate). Never speeds up: overruns are the timeline's job.
    static func fittedRate(speech: TimeInterval, slot: TimeInterval, maxSlowdown: Int) -> Int {
        let rate = Int(((speech / (fitRateTarget * slot) - 1) * 100).rounded())
        return max(-maxSlowdown, min(0, rate))
    }

    /// Synthesise one cue at `rate`% and write it as the pipeline's wav. edge-tts emits mp3;
    /// transcode so trimming/placement treat cloud and local clips identically.
    private func synthesiseCloudClip(binary: URL, text: String, rate: Int, wav: URL) async throws {
        let mp3 = wav.deletingPathExtension().appendingPathExtension("mp3")
        try await synthesiseCue(binary: binary, text: text, rate: rate, out: mp3)
        try await ffmpeg.run(["-i", mp3.path, "-ar", "22050", "-ac", "1",
                              "-c:a", "pcm_s16le", "-y", wav.path])
        try? FileManager.default.removeItem(at: mp3)
    }

    /// Length of a clip's actual speech (leading/trailing silence trimmed, as placement sees it).
    private func speechDuration(of wav: URL) async throws -> TimeInterval {
        let trimmed = wav.deletingPathExtension().appendingPathExtension("fit.wav")
        defer { try? FileManager.default.removeItem(at: trimmed) }
        try await trimSilence(from: wav, to: trimmed)
        return try await ffmpeg.getVideoDuration(url: trimmed)
    }

    /// Synthesise a single cue via the edge-tts CLI, writing an mp3 to `out`. The Microsoft
    /// endpoint intermittently returns no audio (and occasionally rate-limits); left unhandled,
    /// one such blip aborts a whole multi-hundred-cue dub. So retry a few times with a short
    /// backoff, and treat a zero-byte result as a failure too.
    private func synthesiseCue(binary: URL, text: String, rate: Int, out: URL) async throws {
        let maxAttempts = 4
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await runEdgeTTS(binary: binary, text: text, rate: rate, out: out)
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
            + "if this persists, retry later. A handshake/403 error usually means Microsoft changed "
            + "the protocol: `pip install -U edge-tts`.)")
    }

    /// One `edge-tts` CLI call. `--text=`/`--rate=` (not `--text <t>`) so a line or a negative
    /// rate starting with "-" is never taken for an option; word-boundary subtitles go to
    /// /dev/null and the progress bar is off, so the captured stderr holds only a failure message.
    private func runEdgeTTS(binary: URL, text: String, rate: Int, out: URL) async throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--voice", config.cloudVoice, "--text=\(text)",
                             "--rate=\(rate >= 0 ? "+" : "")\(rate)%",
                             "--write-media", out.path, "--write-subtitles", "/dev/null", "--no-progress"]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                guard p.terminationStatus != 0 else { return continuation.resume() }
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let lastLine = stderr.split(separator: "\n").last.map(String.init) ?? ""
                continuation.resume(throwing: CLIError("edge-tts exited with status \(p.terminationStatus): \(lastLine)"))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Elastic timeline (stretch video to fit a natural-speed dub)

    /// Frame rate of the rebuilt timeline. The source is resampled to it first, so every segment
    /// boundary is a whole frame and every segment's output length an exact frame count —
    /// audio placed from the same counts can't drift, however many segments there are.
    private static let timelineFPS = 60

    /// Below this much leftover silence a gap isn't worth its own fast-forward segment.
    private static let minCompressibleGap: TimeInterval = 0.3

    /// One slice of the rebuilt timeline: the original video window `[origStart, origEnd)` held
    /// for `targetDur` — longer than the window means a frozen tail (speech overruns), shorter
    /// means fast-forward (a compressed silent gap) — optionally carrying a dub.
    private struct Segment {
        let origStart: TimeInterval
        let origEnd: TimeInterval
        let targetDur: TimeInterval
        let dub: (wav: URL, position: Int, rawDuration: TimeInterval)?
        var window: TimeInterval { origEnd - origStart }
        var freeze: TimeInterval { max(targetDur - window, 0) }

        /// Source frames `[startFrame, endFrame)` and how many frames they become in the output.
        var frames: (start: Int, end: Int, out: Int) {
            let fps = Double(DubbingService.timelineFPS)
            let start = Int((origStart * fps).rounded())
            let end = max(Int((origEnd * fps).rounded()), start + 1)
            let out = max(Int((targetDur * fps).rounded()), 1)
            return (start, end, out)
        }
    }

    /// Dub by stretching the video instead of compressing the audio: the dub plays at one
    /// natural speed and each cue's video window is frozen-extended just enough to contain it,
    /// so audio and video stay in lockstep and never overlap. The output video is a little longer
    /// than the source, with brief freezes at the densest moments. With `--compress-gaps`, the
    /// silence left after each cue's speech (+ a short pause) is fast-forwarded instead, so the
    /// output gets shorter and the dub is never followed by long dead air.
    private func dubWithStretchedVideo(clips: [(position: Int, start: TimeInterval, raw: TimeInterval, wav: URL)],
                                       texts: [Int: String], srtURL: URL,
                                       videoURL: URL, videoDuration: TimeInterval,
                                       clipDir: URL, output: URL) async throws {
        let tempo = max(config.globalTempo ?? 1.0, 0.5)

        // Tile [0, videoDuration] into segments: an optional leading gap with no dub, then one
        // per cue running to the next cue's start (the last to the video end) — or two, when the
        // cue's silent remainder is fast-forwarded.
        var segments: [Segment] = []
        if clips[0].start > 0.05 {
            segments.append(Segment(origStart: 0, origEnd: clips[0].start,
                                    targetDur: clips[0].start, dub: nil))
        }
        for (i, c) in clips.enumerated() {
            let origEnd = i + 1 < clips.count ? clips[i + 1].start : videoDuration
            let window = max(origEnd - c.start, 0.01)
            let dubDur = c.raw / tempo
            let dub = (c.wav, c.position, c.raw)
            let spoken = dubDur + config.gapPause
            if let factor = config.compressGaps, window - spoken >= Self.minCompressibleGap {
                let split = c.start + spoken
                segments.append(Segment(origStart: c.start, origEnd: split, targetDur: spoken, dub: dub))
                segments.append(Segment(origStart: split, origEnd: origEnd,
                                        targetDur: (origEnd - split) / factor, dub: nil))
            } else {
                segments.append(Segment(origStart: c.start, origEnd: origEnd,
                                        targetDur: max(window, dubDur), dub: dub))
            }
        }

        // New cumulative starts, counted in output frames exactly as buildStretchedVideo renders
        // them; audio placements anchor each dub at its segment start.
        let fps = Double(Self.timelineFPS)
        var placements: [Placement] = []
        var cursorFrames = 0
        for s in segments {
            if let d = s.dub {
                placements.append(Placement(position: d.position, desiredStart: s.origStart,
                                            placedStart: Double(cursorFrames) / fps, budget: s.targetDur,
                                            rawDuration: d.rawDuration, tempo: tempo, wav: d.wav))
            }
            cursorFrames += s.frames.out
        }
        let newTotal = Double(cursorFrames) / fps

        let frozen = segments.filter { $0.freeze > 0.01 }
        let maxFreeze = segments.map(\.freeze).max() ?? 0
        log("Stretch video: dub at ×\(fmt(tempo)) (natural), \(frozen.count) segments extended; "
            + "worst freeze \(fmt(maxFreeze))s.")
        if let factor = config.compressGaps {
            let fast = segments.filter { $0.dub == nil && $0.targetDur < $0.window - 0.01 }
            let saved = fast.reduce(0) { $0 + $1.window - $1.targetDur }
            log("Compress gaps: \(fast.count) silent gaps fast-forwarded ×\(fmt(factor)) "
                + "(after \(fmt(config.gapPause))s pause), \(fmt(saved))s saved.")
        }
        log("Video \(fmt(videoDuration))s → \(fmt(newTotal))s (\(newTotal >= videoDuration ? "+" : "")\(fmt(newTotal - videoDuration))s).")

        // Build the stretched (silent) video — burning subtitles in the same encode — then the
        // natural-speed dub track, then mux.
        let subtitles = try writeSubtitles(placements, texts: texts, totalDuration: newTotal,
                                           srtURL: srtURL, output: output)
        let burn = config.burnSubtitles ? try burnableCopy(of: subtitles) : nil
        defer { if let burn { try? FileManager.default.removeItem(at: burn) } }
        let stretched = clipDir.appendingPathComponent("stretched.mp4")
        let dubTrack = clipDir.appendingPathComponent("dubtrack.wav")
        try await buildStretchedVideo(segments, source: videoURL, burn: burn, output: stretched)
        try await buildDubTrack(placements, totalDuration: newTotal, output: dubTrack)

        let trackDuration = try await ffmpeg.getVideoDuration(url: dubTrack)
        let videoOut = try await ffmpeg.getVideoDuration(url: stretched)
        log("  stretched video \(fmt(videoOut))s, dub track \(fmt(trackDuration))s "
            + (abs(videoOut - trackDuration) < 0.3 ? "(aligned ✓)" : "(⚠️ mismatch)"))

        try await mux(video: stretched, dubTrack: dubTrack, burn: nil, output: output)

        try? FileManager.default.removeItem(at: stretched)
        try? FileManager.default.removeItem(at: dubTrack)
        if config.reuseWavDir == nil { try? FileManager.default.removeItem(at: clipDir) }
    }

    /// Re-encode the source into one video stream where each segment is its original window,
    /// frozen-extended (`tpad`) or fast-forwarded (evenly dropping frames with `select`) to its
    /// target length, then concatenated. The source is first resampled to `timelineFPS` so
    /// segments cut on whole frames and each comes out an exact number of frames.
    /// One `filter_complex` (fps → split → trim/tpad|select/setpts per segment → concat
    /// [→ subtitles]); video only.
    private func buildStretchedVideo(_ segments: [Segment], source: URL, burn: URL?, output: URL) async throws {
        let n = segments.count
        let fps = Self.timelineFPS
        var parts: [String] = []
        let splitOuts = (0..<n).map { "[s\($0)]" }.joined()
        parts.append("[0:v]fps=\(fps),split=\(n)\(splitOuts)")
        var concatIns = ""
        for (i, seg) in segments.enumerated() {
            let f = seg.frames
            let inFrames = f.end - f.start
            var chain = "[s\(i)]trim=start_frame=\(f.start):end_frame=\(f.end),setpts=PTS-STARTPTS"
            if f.out > inFrames {
                chain += ",tpad=stop_mode=clone:stop=\(f.out - inFrames)"
            } else if f.out < inFrames {
                // Keep exactly f.out of the window's frames, evenly spaced, then retime them
                // back to back.
                chain += ",select='gt(floor((n+1)*\(f.out)/\(inFrames))-floor(n*\(f.out)/\(inFrames)),0)'"
                    + ",setpts=N/(\(fps)*TB)"
            }
            chain += "[p\(i)]"
            parts.append(chain)
            concatIns += "[p\(i)]"
        }
        if let burn {
            parts.append("\(concatIns)concat=n=\(n):v=1:a=0[c]")
            parts.append("[c]\(Self.subtitlesFilter(burn))[v]")
        } else {
            parts.append("\(concatIns)concat=n=\(n):v=1:a=0[v]")
        }
        let filter = parts.joined(separator: ";")

        log("Assembling stretched video (\(n) segments, "
            + "\(config.hardwareVideoEncode ? "VideoToolbox HW" : "libx264")"
            + "\(burn != nil ? ", burning subtitles" : ""))…")
        try await ffmpeg.run([
            "-i", source.path,
            "-filter_complex", filter,
            "-map", "[v]", "-an",
            "-r", String(fps), "-fps_mode", "cfr"
        ] + videoEncoderArgs + ["-y", output.path])
    }

    /// Video encoder for every path that can't stream-copy (stretch graph, burned subtitles).
    /// Default to Apple-silicon hardware H.264 (VideoToolbox): constant-quality (-q:v,
    /// resolution-independent) at a few minutes instead of libx264's tens of minutes on a long
    /// 1080p60 lecture. `--sw-encode` forces libx264 for marginally higher quality.
    private var videoEncoderArgs: [String] {
        if config.hardwareVideoEncode {
            return ["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1",
                    "-profile:v", "high", "-pix_fmt", "yuv420p"]
        }
        return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]
    }

    // MARK: - Subtitles

    /// Longest reading subtitle in characters — about two lines at the burned style's size.
    private static let subtitleMaxChars = 84

    /// Burned-in style (libass `force_style`): white text, black outline, bottom centre. libass
    /// scales FontSize with the video height, so it reads the same at 720p and 1080p.
    private static let subtitleStyle = "FontName=Helvetica,FontSize=15,PrimaryColour=&H00FFFFFF,"
        + "OutlineColour=&H00000000,BorderStyle=1,Outline=1.6,Shadow=0,MarginV=14"

    private static func subtitlesFilter(_ srt: URL) -> String {
        "subtitles=filename='\(srt.path)':force_style='\(subtitleStyle)'"
    }

    /// Write reading subtitles on the *output* timeline next to `output` (`<name>.srt`, or
    /// `<name>.retimed.srt` if that is the input SRT): each cue's text split into ≤2-line chunks
    /// spread over its spoken placement by length, the last held until the next cue starts.
    /// Letters spelled out for the TTS ("A I") are joined back ("AI") for reading.
    private func writeSubtitles(_ placements: [Placement], texts: [Int: String], totalDuration: TimeInterval,
                                srtURL: URL, output: URL) throws -> URL {
        let sorted = placements.sorted { $0.placedStart < $1.placedStart }
        var blocks: [String] = []
        for (i, p) in sorted.enumerated() {
            guard let text = texts[p.position] else { continue }
            let chunks = Self.readingChunks(Self.rejoinSpelledLetters(
                text.replacingOccurrences(of: "\n", with: " ")))
            guard !chunks.isEmpty else { continue }
            let next = i + 1 < sorted.count ? sorted[i + 1].placedStart : totalDuration
            let totalChars = Double(chunks.reduce(0) { $0 + $1.count })
            var t = p.placedStart
            for (k, chunk) in chunks.enumerated() {
                let end = k == chunks.count - 1
                    ? max(next - 0.05, t + 0.3)
                    : t + p.fittedDuration * Double(chunk.count) / totalChars
                blocks.append("\(blocks.count + 1)\n\(Self.srtTime(t)) --> \(Self.srtTime(end))\n\(chunk)\n")
                t = end
            }
        }
        var url = output.deletingPathExtension().appendingPathExtension("srt")
        if url.standardizedFileURL == srtURL.standardizedFileURL {
            url = output.deletingPathExtension().appendingPathExtension("retimed.srt")
        }
        try blocks.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        log("Subtitles on the output timeline: \(url.path)")
        return url
    }

    /// The subtitles filter takes a path inside a filtergraph, where quotes, colons and
    /// backslashes in a user's directory name would need escaping; a temp copy sidesteps that.
    private func burnableCopy(of srt: URL) throws -> URL {
        let copy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("breeze-dub-subs-\(UUID().uuidString).srt")
        try FileManager.default.copyItem(at: srt, to: copy)
        return copy
    }

    /// Split a cue into reading chunks of at most `maxChars`, preferring breaks after clause
    /// punctuation, then packing words greedily.
    static func readingChunks(_ text: String, maxChars: Int = subtitleMaxChars) -> [String] {
        var clauses: [[Substring]] = [[]]
        for word in text.split(separator: " ") {
            clauses[clauses.count - 1].append(word)
            if let last = word.last, ".?!;,—".contains(last) { clauses.append([]) }
        }
        var chunks: [String] = []
        var current = ""
        for clause in clauses where !clause.isEmpty {
            let joined = clause.joined(separator: " ")
            for piece in joined.count <= maxChars ? [joined] : clause.map(String.init) {
                let candidate = current.isEmpty ? piece : current + " " + piece
                if candidate.count <= maxChars {
                    current = candidate
                } else {
                    if !current.isEmpty { chunks.append(current) }
                    current = piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// "A I" → "AI", "G P T" → "GPT": runs of single capital letters the dub prompt spells out
    /// so the TTS says each letter.
    static func rejoinSpelledLetters(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: "\\b[A-Z](?: [A-Z]\\b)+")
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: result[range].replacingOccurrences(of: " ", with: ""))
        }
        return result
    }

    static func srtTime(_ t: TimeInterval) -> String {
        let ms = max(Int((t * 1000).rounded()), 0)
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
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

    /// Mux the dub track into `video`, stream-copying the picture unless `burn` subtitles must be
    /// rendered into it.
    private func mux(video: URL, dubTrack: URL, burn: URL?, output: URL) async throws {
        log("Muxing dub into video\(burn != nil ? " (burning subtitles)" : "")…")
        var args = ["-i", video.path, "-i", dubTrack.path]
        var graph: [String] = []
        var videoMap = "0:v:0"
        var audioMap = "1:a:0"   // default: replace the audio entirely with the dub
        if config.keepOriginalVolume > 0 {
            // Duck the original speech under the dub instead of replacing it.
            graph.append("[0:a]volume=\(String(format: "%.3f", config.keepOriginalVolume))[orig];"
                + "[orig][1:a]amix=inputs=2:normalize=0:dropout_transition=0[a]")
            audioMap = "[a]"
        }
        if let burn {
            graph.append("[0:v]\(Self.subtitlesFilter(burn))[v]")
            videoMap = "[v]"
        }
        if !graph.isEmpty { args += ["-filter_complex", graph.joined(separator: ";")] }
        args += ["-map", videoMap, "-map", audioMap]
        args += burn != nil ? videoEncoderArgs : ["-c:v", "copy"]
        args += [
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
