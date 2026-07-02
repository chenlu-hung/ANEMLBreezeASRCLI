import Foundation

/// breeze-asr — headless Breeze-ASR-25 transcription CLI.
///
///   breeze-asr <input> [-l <lang>] [-o <out.srt>] [--model-path <dir>] [-q]
///
/// Pipeline: FFmpeg extracts a 16 kHz mono WAV → WhisperKit/Breeze-ASR-25 transcribes
/// → a standard SRT is written. LLM correction/translation is NOT done here; the
/// breeze-asr-subtitle skill delegates that to opencode.
@main
struct BreezeASRCLI {
    /// Synchronous entry point. The real work runs on a detached background Task while
    /// the main thread stays in `dispatchMain()` servicing the main queue — CoreML/ANE
    /// model loading dispatches completions there, so occupying the main thread with an
    /// `async` main (the default `@main async` pattern) deadlocks the WhisperKit load.
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.first == "-h" || args.first == "--help" {
            printUsage()
            exit(args.isEmpty ? 1 : 0)
        }

        // Subcommand: `breeze-asr dub <video> --srt <translated.srt> …`
        if args.first == "dub" {
            let dubArgs = Array(args.dropFirst())
            if dubArgs.isEmpty || dubArgs.contains("-h") || dubArgs.contains("--help") {
                printDubUsage()
                exit(dubArgs.isEmpty ? 1 : 0)
            }
            Task.detached {
                do {
                    let options = try DubOptions(parsing: dubArgs)
                    try await runDub(options)
                    exit(0)
                } catch let error as CLIError {
                    FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
                    exit(1)
                } catch {
                    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }

        Task.detached {
            do {
                let options = try Options(parsing: args)
                try await run(options)
                exit(0)
            } catch let error as CLIError {
                FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
                exit(1)
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        dispatchMain()
    }

    static func run(_ options: Options) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: options.input.path) else {
            throw CLIError("Input file not found: \(options.input.path)")
        }

        let outputURL = options.output ?? options.input.deletingPathExtension().appendingPathExtension("srt")

        // 1. Extract 16 kHz mono WAV to a temp file.
        let ffmpeg = FFmpegService()
        try ffmpeg.checkFFmpegAvailable()

        let tempAudio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("breeze-asr-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: tempAudio) }

        log(options, "Extracting audio…")
        try await ffmpeg.extractAudio(from: options.input, to: tempAudio) { progress in
            progressBar(options, label: "audio", value: progress)
        }
        logDone(options)

        // 2. Load the Breeze-ASR-25 model (reuses an existing cache if present).
        let whisper = WhisperKitService(modelPathOverride: options.modelPath, computeBackend: options.compute)
        log(options, "Loading Breeze-ASR-25 model…")
        try await whisper.initialize { progress in
            progressBar(options, label: "model", value: progress)
        }
        logDone(options)

        // 3. Transcribe.
        log(options, "Transcribing (\(options.language.displayName))…")
        let segments = try await whisper.transcribe(audioURL: tempAudio, language: options.language) { progress in
            progressBar(options, label: "asr", value: progress)
        }
        logDone(options)

        guard !segments.isEmpty else {
            throw CLIError("Transcription produced no segments.")
        }

        // 4. Write SRT.
        try SubtitleService().generateSRT(from: segments, outputURL: outputURL)
        log(options, "Wrote \(segments.count) cues.")

        // stdout: just the SRT path, so a caller (the skill) can capture it cleanly.
        print(outputURL.path)
    }

    // MARK: - Dub subcommand

    static func runDub(_ options: DubOptions) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: options.video.path) else {
            throw CLIError("Video not found: \(options.video.path)")
        }
        guard fm.fileExists(atPath: options.srt.path) else {
            throw CLIError("SRT not found: \(options.srt.path)")
        }
        if let ref = options.refWav, !fm.fileExists(atPath: ref.path) {
            throw CLIError("Voice reference not found: \(ref.path)")
        }

        let ffmpeg = FFmpegService()
        try ffmpeg.checkFFmpegAvailable()

        let output = options.output
            ?? options.video.deletingPathExtension().appendingPathExtension("dubbed.mp4")

        let config = DubbingService.Config(
            indexTTSBinary: options.indexTTSBinary,
            modelDir: options.modelDir,
            refWav: options.refWav,
            refStart: options.refStart,
            refDuration: options.refDuration,
            preprocDir: options.preprocDir,
            diffusionSteps: options.diffusionSteps,
            maxSpeedup: options.maxSpeedup,
            keepOriginalVolume: options.keepOriginalVolume,
            reuseWavDir: options.reuseWavDir,
            uniformSpeed: options.uniformSpeed,
            globalTempo: options.globalTempo,
            trimSilence: options.trimSilence,
            stretchVideo: options.stretchVideo,
            quiet: options.quiet
        )
        let service = DubbingService(ffmpeg: ffmpeg, config: config)
        try await service.dub(srt: options.srt, video: options.video, output: output)

        // stdout: the dubbed video path, so a caller can capture it cleanly.
        print(output.path)
    }

    // MARK: - Output helpers (logs to stderr, result to stdout)

    static func log(_ options: Options, _ message: String) {
        guard !options.quiet else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func logDone(_ options: Options) {
        guard !options.quiet else { return }
        FileHandle.standardError.write(Data("  done.\n".utf8))
    }

    static func progressBar(_ options: Options, label: String, value: Double) {
        guard !options.quiet else { return }
        let pct = Int(value * 100)
        FileHandle.standardError.write(Data("\r  [\(label)] \(pct)%   ".utf8))
    }

    static func printUsage() {
        let usage = """
        breeze-asr — Breeze-ASR-25 subtitle transcription

        USAGE:
          breeze-asr <input> [options]

        ARGUMENTS:
          <input>                 Video or audio file (anything FFmpeg can read)

        OPTIONS:
          -l, --language <code>   Source language code (default: auto).
                                  zh en ja ko es fr de it pt ru ar hi auto
          -o, --output <path>     Output SRT path (default: <input>.srt)
              --model-path <dir>  Use a specific Breeze-ASR-25 model folder
              --compute <backend> Compute units: ane (default) or gpu. The first ANE run does a
                                  one-time compile that can take ~40 min (NOT a hang — let it
                                  finish); after that it's cached and loads in ~3 s. Pass 'gpu'
                                  to skip the compile (instant load, slower on Apple silicon).
          -q, --quiet             Suppress progress output
          -h, --help              Show this help

        SUBCOMMANDS:
          dub <video> --srt <file>   Generate a time-aligned dub and mux it into the video
                                     (see `breeze-asr dub --help`)

        OUTPUT:
          Progress is written to stderr; the final SRT path is printed to stdout.
        """
        print(usage)
    }

    static func printDubUsage() {
        let defaults = DubOptions.Defaults.self
        let usage = """
        breeze-asr dub — synthesise a time-aligned dub from a translated SRT

        USAGE:
          breeze-asr dub <video> --srt <translated.srt> [options]

        ARGUMENTS:
          <video>                  Source video to dub (FFmpeg-readable)

        OPTIONS:
          --srt <path>             (required) Translated SRT to voice
          --ref <wav>              Voice reference for cloning. Default: extract one straight
                                   from the source video (clone the original speaker).
          --ref-start <sec>        Start of the auto-extracted reference clip
                                   (default: the first cue's start)
          --ref-duration <sec>     Length of the auto-extracted reference clip
                                   (default: \(defaults.refDuration))
          --indextts2 <path>       indextts2 binary
                                   (default: \(defaults.binary))
          --model <dir>            indextts2 model dir
                                   (default: \(defaults.model))
          --preproc-dir <dir>      indextts2 preprocessing weights dir (optional)
          --steps <n>              indextts2 diffusion steps per cue (1–100, default \(defaults.diffusionSteps)).
                                   Fewer steps synthesise faster with slightly lower quality;
                                   the engine's own default is 25.
          -o, --output <path>      Output video (default: <video>.dubbed.mp4)
          --max-speedup <f>        (sequential mode) Max atempo to fit a clip into its slot
                                   (1.0–2.0, default \(defaults.maxSpeedup))
          --uniform-speed          One global tempo for the whole video, every cue anchored to
                                   its own start time (constant speed, zero drift; the tightest
                                   lines may overlap the next cue — those are reported)
          --speed <f>              Force the global tempo (0.5–3.0); implies --uniform-speed.
                                   Without it, --uniform-speed auto-fits the video length.
          --stretch-video          Keep the dub at natural speed and instead freeze-extend the
                                   video at dense cues so nothing overlaps and audio/video stay
                                   locked (output video is a little longer). Uses --speed if given.
          --no-trim-silence        Keep indextts2's leading/trailing clip silence
                                   (default: trim it, for tighter onset sync and less speed-up)
          --keep-original <vol>    Keep original audio at this volume under the dub
                                   (0 = replace, default 0)
          --wav-dir <dir>          Reuse clips already generated in <dir> (skip TTS)
          -q, --quiet              Suppress progress output
          -h, --help               Show this help

        OUTPUT:
          Progress/timeline report on stderr; the dubbed video path on stdout.
        """
        print(usage)
    }
}

struct CLIError: Error { let message: String; init(_ m: String) { message = m } }

struct Options: Sendable {
    let input: URL
    var output: URL?
    var language: SupportedLanguage = .auto
    var modelPath: URL?
    var compute: ComputeBackend = .ane
    var quiet = false

    init(parsing args: [String]) throws {
        var input: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-l", "--language":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for \(arg)") }
                guard let lang = SupportedLanguage(rawValue: args[i]) else {
                    throw CLIError("Unsupported language '\(args[i])'. Use one of: \(SupportedLanguage.allCases.map(\.rawValue).joined(separator: " "))")
                }
                language = lang
            case "-o", "--output":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for \(arg)") }
                output = URL(fileURLWithPath: args[i])
            case "--model-path":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for \(arg)") }
                modelPath = URL(fileURLWithPath: args[i], isDirectory: true)
            case "--compute":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for \(arg)") }
                guard let backend = ComputeBackend(rawValue: args[i].lowercased()) else {
                    throw CLIError("Unsupported compute backend '\(args[i])'. Use 'gpu' or 'ane'.")
                }
                compute = backend
            case "-q", "--quiet":
                quiet = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIError("Unknown option: \(arg)")
                }
                if input != nil { throw CLIError("Unexpected extra argument: \(arg)") }
                input = arg
            }
            i += 1
        }

        guard let input else { throw CLIError("No input file given.") }
        self.input = URL(fileURLWithPath: input)
    }
}

/// Parsed arguments for `breeze-asr dub`. Defaults for the indextts2 binary, model and
/// voice reference are resolved relative to the current working directory following the
/// `../indextts2-mlx/` sibling-repo convention; override any of them with explicit flags.
struct DubOptions: Sendable {
    let video: URL
    var srt: URL
    var refWav: URL?                // nil = extract a voice reference from the video
    var refStart: TimeInterval?     // start of the auto-extracted reference clip; nil = first cue
    var refDuration: TimeInterval = Defaults.refDurationValue
    var indexTTSBinary: URL
    var modelDir: URL
    var preprocDir: URL?
    var output: URL?
    var diffusionSteps: Int = Defaults.diffusionStepsValue
    var maxSpeedup: Double = Defaults.maxSpeedupValue
    var keepOriginalVolume: Double = 0
    var reuseWavDir: URL?
    var uniformSpeed = false
    var globalTempo: Double?
    var trimSilence = true
    var stretchVideo = false
    var quiet = false

    enum Defaults {
        static let binary = "../indextts2-mlx/.build/xcode/Build/Products/Debug/indextts2"
        static let model = "../indextts2-mlx/models/mlx-indextts2-standard-8bit"
        static let maxSpeedupValue = 1.5
        static var maxSpeedup: String { String(maxSpeedupValue) }
        static let diffusionStepsValue = 20
        static var diffusionSteps: String { String(diffusionStepsValue) }
        static let refDurationValue: TimeInterval = 15
        static var refDuration: String { String(Int(refDurationValue)) }
    }

    init(parsing args: [String]) throws {
        var video: String?
        var srt: String?
        var ref: String?
        var binary = Defaults.binary
        var model = Defaults.model

        var i = 0
        while i < args.count {
            let arg = args[i]
            func value() throws -> String {
                i += 1
                guard i < args.count else { throw CLIError("Missing value for \(arg)") }
                return args[i]
            }
            switch arg {
            case "--srt":            srt = try value()
            case "--ref":            ref = try value()
            case "--ref-start":
                guard let v = Double(try value()), v >= 0 else {
                    throw CLIError("--ref-start must be a non-negative time in seconds")
                }
                refStart = v
            case "--ref-duration":
                guard let v = Double(try value()), v >= 0.5 else {
                    throw CLIError("--ref-duration must be at least 0.5 seconds")
                }
                refDuration = v
            case "--indextts2":      binary = try value()
            case "--model":          model = try value()
            case "--preproc-dir":    preprocDir = DubOptions.absolute(try value(), isDirectory: true)
            case "--steps":
                guard let v = Int(try value()), v >= 1, v <= 100 else {
                    throw CLIError("--steps must be an integer between 1 and 100")
                }
                diffusionSteps = v
            case "-o", "--output":   output = DubOptions.absolute(try value())
            case "--max-speedup":
                guard let v = Double(try value()), v >= 1.0, v <= 2.0 else {
                    throw CLIError("--max-speedup must be between 1.0 and 2.0 (atempo's single-filter range)")
                }
                maxSpeedup = v
            case "--keep-original":
                guard let v = Double(try value()), v >= 0 else {
                    throw CLIError("--keep-original must be a non-negative volume (0 = replace)")
                }
                keepOriginalVolume = v
            case "--wav-dir":        reuseWavDir = DubOptions.absolute(try value(), isDirectory: true)
            case "--uniform-speed":  uniformSpeed = true
            case "--stretch-video":  stretchVideo = true
            case "--no-trim-silence": trimSilence = false
            case "--speed":
                guard let v = Double(try value()), v >= 0.5, v <= 3.0 else {
                    throw CLIError("--speed must be between 0.5 and 3.0")
                }
                globalTempo = v
                uniformSpeed = true   // an explicit global tempo implies uniform mode
            case "-q", "--quiet":    quiet = true
            default:
                if arg.hasPrefix("-") { throw CLIError("Unknown option: \(arg)") }
                if video != nil { throw CLIError("Unexpected extra argument: \(arg)") }
                video = arg
            }
            i += 1
        }

        guard let video else { throw CLIError("No video given. Usage: breeze-asr dub <video> --srt <file>") }
        guard let srt else { throw CLIError("Missing required --srt <translated.srt>") }
        self.video = DubOptions.absolute(video)
        self.srt = DubOptions.absolute(srt)
        self.refWav = ref.map { DubOptions.absolute($0) }
        self.indexTTSBinary = DubOptions.absolute(binary)
        self.modelDir = DubOptions.absolute(model, isDirectory: true)
    }

    /// Resolve a user-supplied path to an absolute, `..`-collapsed file URL. Relative paths
    /// are taken against the current working directory. Needed because `Process.executableURL`
    /// (used to launch indextts2) will not start from a relative path, even though
    /// `FileManager.fileExists` happily resolves one.
    static func absolute(_ path: String, isDirectory: Bool = false) -> URL {
        let base = URL(fileURLWithPath: path, isDirectory: isDirectory)
        return base.standardizedFileURL
    }
}
