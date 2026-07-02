import Foundation
import WhisperKit
import Hub
import CoreML

/// Which CoreML compute units to load the Breeze model on.
/// `.ane` is the default — on Apple silicon the NPU beats the GPU for this model. `.gpu` is the
/// instant-load fallback. `.ane` is NOT a deadlock in this unsigned CLI — but the FIRST `.ane`
/// run triggers a one-time cold ANE compile of the 1.2 GB Breeze encoder that can take tens of
/// minutes (~40 min observed here); don't kill it. The
/// result is cached by ANECompilerService under THIS binary's bundle id (`breeze-asr`), in
/// `~/Library/Caches/breeze-asr/com.apple.e5rt.e5bundlecache`. That cache is keyed per bundle id,
/// so VibeTyping's warm ANE compile can't be inherited (the `.mlmodelc` model files are shared,
/// the ANE bundle is not). Once warm, `.ane` loads in ~3 s.
enum ComputeBackend: String, Sendable {
    case gpu
    case ane

    var computeUnits: MLComputeUnits {
        switch self {
        case .gpu: return .cpuAndGPU
        case .ane: return .cpuAndNeuralEngine
        }
    }
}

enum WhisperKitError: LocalizedError {
    case notInitialized
    case initializationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit not initialized"
        case .initializationFailed(let message):
            return "WhisperKit initialization failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

/// WhisperKit wrapper around the Breeze-ASR-25 CoreML model.
/// Reuses a model already cached by the ANEMLBreezeASR GUI app or by VibeTyping
/// before downloading anything (so the skill never re-fetches the ~3 GB model).
/// NOT @MainActor (unlike the GUI service): loading the CoreML model on the main
/// thread of an async CLI deadlocks, since ANE completions need the main thread free.
final class WhisperKitService {
    private var whisperKit: WhisperKit?

    private static let modelRepo = "aoiandroid/Breeze-ASR-25_coreml"

    private let modelPathOverride: URL?
    private let computeBackend: ComputeBackend

    init(modelPathOverride: URL? = nil, computeBackend: ComputeBackend = .ane) {
        self.modelPathOverride = modelPathOverride
        self.computeBackend = computeBackend
    }

    private func appSupportCache(_ appFolder: String) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("\(appFolder)/HubCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Caches searched for an existing model, in priority order.
    private var candidateCaches: [URL] {
        [
            appSupportCache("ANEMLBreezeASR"),   // shared with the GUI app
            appSupportCache("VibeTyping")        // shared with VibeTyping
        ]
    }

    var isInitialized: Bool { whisperKit != nil }

    func initialize(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        do {
            let modelFolder: URL

            if let override = modelPathOverride, isValidModelFolder(override) {
                modelFolder = override
                progressHandler(1.0)
                NSLog("breeze-asr: Using model override: \(override.path)")
            } else if let cached = candidateCaches.compactMap({ findModelInCache($0) }).first {
                modelFolder = cached
                progressHandler(1.0)
                NSLog("breeze-asr: Reusing cached model: \(cached.path)")
            } else {
                let ownCache = appSupportCache("ANEMLBreezeASR")
                NSLog("breeze-asr: Downloading model from \(Self.modelRepo)...")
                let hubApi = HubApi(downloadBase: ownCache)
                let repo = Hub.Repo(id: Self.modelRepo, type: .models)
                modelFolder = try await hubApi.snapshot(
                    from: repo,
                    matching: ["*.mlmodelc/*", "*.json", "*.txt"],
                    progressHandler: { progress in progressHandler(progress.fractionCompleted) }
                )
                NSLog("breeze-asr: Model downloaded to: \(modelFolder.path)")
            }

            // The Breeze model folder bundles no tokenizer, so WhisperKit downloads the
            // Whisper tokenizer. Its default target is ~/Documents/huggingface, which is
            // TCC-protected for an unsigned CLI ("you don't have permission"). Point it at
            // our own writable app-support cache instead.
            let tokenizerCache = appSupportCache("ANEMLBreezeASR")

            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerCache,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: computeBackend.computeUnits,
                    textDecoderCompute: computeBackend.computeUnits
                ),
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )

            NSLog("breeze-asr: Loading model on \(computeBackend.rawValue.uppercased())…")
            whisperKit = try await WhisperKit(config)
            progressHandler(1.0)
            NSLog("breeze-asr: WhisperKit model loaded")
        } catch {
            throw WhisperKitError.initializationFailed(error.localizedDescription)
        }
    }

    func transcribe(audioURL: URL, language: SupportedLanguage = .auto, progressHandler: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptionSegment] {
        guard let kit = whisperKit else {
            throw WhisperKitError.notInitialized
        }

        do {
            progressHandler(0.0)

            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language.whisperCode,
                temperature: 0.0,
                temperatureFallbackCount: 5,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                clipTimestamps: [],
                suppressBlank: true,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6,
                chunkingStrategy: .vad
            )

            let result = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
            progressHandler(1.0)

            // VAD chunking returns multiple results; flatten, sort by start time.
            let allSegments = result
                .flatMap { $0.segments }
                .sorted { $0.start < $1.start }

            return allSegments.enumerated().map { index, segment in
                TranscriptionSegment(
                    id: index,
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    text: segment.text
                )
            }
        } catch {
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Model cache resolution

    private static let requiredComponents = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc"
    ]

    /// Real AudioEncoder.mlmodelc is ~1.2 GB; HF download stubs are only a few KB.
    private static let minAudioEncoderBytes: Int64 = 100 * 1024 * 1024  // 100 MB

    private func findModelInCache(_ baseURL: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return nil }

        // Canonical Hub layout: <base>/models/<repo>/
        let canonical = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent(Self.modelRepo)
        if isValidModelFolder(canonical) { return canonical }

        // Fallback: recursive search, skipping the HF download stub cache.
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if fileURL.pathComponents.contains(".cache") { continue }
            if fileURL.lastPathComponent == "AudioEncoder.mlmodelc" {
                let candidate = fileURL.deletingLastPathComponent()
                if isValidModelFolder(candidate) { return candidate }
            }
        }
        return nil
    }

    private func isValidModelFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        for component in Self.requiredComponents {
            let path = folder.appendingPathComponent(component).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
        }
        let audioEncoder = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        return directorySize(at: audioEncoder) >= Self.minAudioEncoderBytes
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
