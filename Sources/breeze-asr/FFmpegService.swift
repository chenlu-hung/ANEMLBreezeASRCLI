import Foundation

enum FFmpegError: LocalizedError {
    case notFound
    case executionFailed(String)
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "FFmpeg not found. Please install FFmpeg using: brew install ffmpeg"
        case .executionFailed(let message):
            return "FFmpeg execution failed: \(message)"
        case .invalidDuration:
            return "Could not determine video duration"
        }
    }
}

/// Extracts a 16 kHz mono WAV from any audio/video file FFmpeg can read.
/// Ported from the GUI app, minus the subtitle-burning path (skill is ASR-only).
/// NOT @MainActor (unlike the GUI service): in a CLI the WhisperKit/CoreML load must
/// stay off the main thread so ANE completions can be serviced, avoiding a deadlock.
final class FFmpegService {
    private var ffmpegPath: String?

    init() {
        self.ffmpegPath = Self.findFFmpeg()
    }

    private static func findFFmpeg() -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        for path in possiblePaths where FileManager.default.fileExists(atPath: path) {
            return path
        }

        // Fall back to `which ffmpeg`.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        return nil
    }

    func checkFFmpegAvailable() throws {
        guard ffmpegPath != nil else {
            throw FFmpegError.notFound
        }
    }

    func getVideoDuration(url: URL) async throws -> TimeInterval {
        guard let ffmpegPath = ffmpegPath else {
            throw FFmpegError.notFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-i", url.path, "-hide_banner"]

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            var errorOutput = ""
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if let output = String(data: handle.availableData, encoding: .utf8) {
                    errorOutput += output
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
                errorPipe.fileHandleForReading.readabilityHandler = nil

                // Parse "Duration: 00:01:23.45" from FFmpeg's banner.
                if let durationMatch = errorOutput.range(of: "Duration: (\\d+):(\\d+):(\\d+\\.\\d+)", options: .regularExpression) {
                    let durationStr = String(errorOutput[durationMatch])
                    let components = durationStr.replacingOccurrences(of: "Duration: ", with: "").split(separator: ":")
                    if components.count == 3,
                       let hours = Double(components[0]),
                       let minutes = Double(components[1]),
                       let seconds = Double(components[2]) {
                        continuation.resume(returning: hours * 3600 + minutes * 60 + seconds)
                        return
                    }
                }
                continuation.resume(throwing: FFmpegError.invalidDuration)
            } catch {
                continuation.resume(throwing: FFmpegError.executionFailed(error.localizedDescription))
            }
        }
    }

    /// Run ffmpeg with arbitrary arguments, capturing stderr. Throws on a non-zero exit,
    /// surfacing the tail of ffmpeg's stderr so filtergraph/mux errors are legible.
    /// Used by the dubbing pipeline (silence-padded mix, mux) where there is no single
    /// progress duration to track.
    @discardableResult
    func run(_ arguments: [String]) async throws -> String {
        guard let ffmpegPath = ffmpegPath else {
            throw FFmpegError.notFound
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = arguments

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            var errorOutput = ""
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if let output = String(data: handle.availableData, encoding: .utf8) {
                    errorOutput += output
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    continuation.resume(returning: errorOutput)
                } else {
                    let tail = errorOutput.split(separator: "\n").suffix(8).joined(separator: "\n")
                    continuation.resume(throwing: FFmpegError.executionFailed("exit \(process.terminationStatus):\n\(tail)"))
                }
            } catch {
                continuation.resume(throwing: FFmpegError.executionFailed(error.localizedDescription))
            }
        }
    }

    /// Extract a short reference clip of the original speaker for voice cloning: `duration`
    /// seconds starting at `start`, downmixed to mono PCM at 24 kHz (a clean, resampler-friendly
    /// reference for indextts2). Seeks before `-i` for a fast, frame-accurate-enough cut.
    func extractReferenceClip(from videoURL: URL, to wavURL: URL,
                              start: TimeInterval, duration: TimeInterval) async throws {
        try await run([
            "-ss", String(format: "%.3f", start),
            "-i", videoURL.path,
            "-t", String(format: "%.3f", duration),
            "-vn", "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le",
            "-y", wavURL.path
        ])
    }

    func extractAudio(from videoURL: URL, to audioURL: URL, progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        guard let ffmpegPath = ffmpegPath else {
            throw FFmpegError.notFound
        }

        let duration = (try? await getVideoDuration(url: videoURL)) ?? 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-i", videoURL.path,
                "-vn",
                "-acodec", "pcm_s16le",
                "-ar", "16000",
                "-ac", "1",
                "-y",
                audioURL.path
            ]

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            var hasResumed = false

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                guard duration > 0,
                      let output = String(data: handle.availableData, encoding: .utf8) else { return }
                // Parse "time=00:01:23.45" progress markers.
                if let timeMatch = output.range(of: "time=(\\d+):(\\d+):(\\d+\\.\\d+)", options: .regularExpression) {
                    let timeStr = String(output[timeMatch])
                    let components = timeStr.replacingOccurrences(of: "time=", with: "").split(separator: ":")
                    if components.count == 3,
                       let hours = Double(components[0]),
                       let minutes = Double(components[1]),
                       let seconds = Double(components[2]) {
                        let currentTime = hours * 3600 + minutes * 60 + seconds
                        let progress = min(currentTime / duration, 1.0)
                        progressHandler(progress)
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
                errorPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    if !hasResumed {
                        hasResumed = true
                        progressHandler(1.0)
                        continuation.resume()
                    }
                } else if !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: FFmpegError.executionFailed("Process terminated with status \(process.terminationStatus)"))
                }
            } catch {
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: FFmpegError.executionFailed(error.localizedDescription))
                }
            }
        }
    }
}
