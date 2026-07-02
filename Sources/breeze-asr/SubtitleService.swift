import Foundation
import SwiftSubtitles

enum SubtitleError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return "Failed to write SRT file: \(message)"
        }
    }
}

/// One transcription segment with its time range. Produced by `WhisperKitService`,
/// consumed by `SubtitleService.generateSRT`.
struct TranscriptionSegment {
    let id: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

/// Writes transcription segments to a standard SRT file via SwiftSubtitles.
/// (The GUI app's LLM correction / timestamp-reattach logic is intentionally NOT
/// ported here — in the skill that work is delegated to opencode.)
struct SubtitleService {
    func generateSRT(from segments: [TranscriptionSegment], outputURL: URL) throws {
        let subtitleCues = segments.enumerated().map { index, segment in
            Subtitles.Cue(
                position: index + 1,
                startTime: timeIntervalToSubtitlesTime(segment.startTime),
                endTime: timeIntervalToSubtitlesTime(segment.endTime),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let subtitles = Subtitles(subtitleCues)

        do {
            let srtContent = try Subtitles.encode(subtitles, fileExtension: "srt")
            try srtContent.write(to: outputURL, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            throw SubtitleError.writeFailed(error.localizedDescription)
        }
    }

    private func timeIntervalToSubtitlesTime(_ interval: TimeInterval) -> Subtitles.Time {
        let totalMilliseconds = Int(interval * 1000)
        let hours = UInt(totalMilliseconds / 3_600_000)
        let minutes = UInt((totalMilliseconds % 3_600_000) / 60_000)
        let seconds = UInt((totalMilliseconds % 60_000) / 1_000)
        let milliseconds = UInt(totalMilliseconds % 1_000)

        return Subtitles.Time(
            hour: hours,
            minute: minutes,
            second: seconds,
            millisecond: milliseconds
        )
    }
}
