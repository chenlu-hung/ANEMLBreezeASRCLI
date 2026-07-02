# Module: `(root)`

## Summary
Swift Package manifest for the `breeze-asr` executable. Declares macOS 13+ as the platform
and pins four dependencies: WhisperKit (Breeze-ASR-25 CoreML inference), swift-transformers'
`Hub` (model download/cache), SwiftSubtitles (SRT read/write), and SwiftEdgeTTS (pure-Swift
edge-tts client for the default cloud dub TTS — no Python, no external binary). The single
executable target builds everything under `Sources/breeze-asr`.

<!-- projectmap:auto:start (generated — do not edit by hand) -->
## Files (1)
- `Package.swift`

## Public symbols (0)

## Dependencies (imports)
- `PackageDescription`
<!-- projectmap:auto:end -->
