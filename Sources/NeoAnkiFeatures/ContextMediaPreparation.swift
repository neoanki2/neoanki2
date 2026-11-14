import Foundation
import NeoAnkiApplication
import NeoAnkiCore
@preconcurrency import AVFoundation
#if canImport(Speech)
import Speech
#endif

public enum ContextMediaPreparation {
    public static func clip(url: URL, kind: MediaKind, start: Double, end: Double) async throws -> Data {
        guard url.isFileURL, start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 60 else {
            throw ContextAuthoringError.message("Choose a clip between 0 and 60 seconds with valid start and end times.")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, end <= duration + 0.05 else { throw ContextAuthoringError.message("The clip ends after the source media. Adjust its boundaries.") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("context-clip-\(UUID()).\(kind == .video ? "mp4" : "m4a")")
        defer { try? FileManager.default.removeItem(at: output) }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: kind == .video ? AVAssetExportPresetMediumQuality : AVAssetExportPresetAppleM4A) else {
            throw ContextAuthoringError.message("This media cannot be exported. Choose a different file.")
        }
        exporter.outputURL = output; exporter.outputFileType = kind == .video ? .mp4 : .m4a
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                         end: CMTime(seconds: end, preferredTimescale: 600))
        exporter.fileLengthLimit = Int64(MediaValidation.maxBytes(for: kind))
        await exporter.export()
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw exporter.error ?? ContextAuthoringError.message("The clip could not be exported. Your draft is preserved.") }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= MediaValidation.maxBytes(for: kind) else { throw MediaError.fileTooLarge(kind, maxBytes: MediaValidation.maxBytes(for: kind)) }
        return try Data(contentsOf: output)
    }
}

public enum ContextTranscription {
    public static func availability(language: String) async -> ContextCapability {
        #if canImport(Speech)
        if #available(macOS 26, iOS 26, *) {
            guard SpeechTranscriber.isAvailable else { return .unavailable("On-device transcription is unavailable on this device. Import SRT or VTT subtitles instead.") }
            let locales = await SpeechTranscriber.installedLocales
            guard locales.contains(where: { $0.language.languageCode == Locale(identifier: language).language.languageCode }) else {
                return .unavailable("No speech model is installed for this language. Install it in system settings or import subtitles.")
            }
            return .available
        }
        #endif
        return .unavailable("On-device transcription needs macOS 26 or iOS 26. Import SRT or VTT subtitles instead.")
    }

    public static func run(source: ContextSource, library: ContextSourceLibrary) async throws {
        if let reason = await availability(language: source.language).reason { throw ContextAuthoringError.message(reason) }
        #if canImport(Speech)
        if #available(macOS 26, iOS 26, *) {
            let sourceURL = try await library.mediaURL(for: source)
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw ContextAuthoringError.message("This source has no readable audio duration.") }
            // Finalized 30-second chunks are durable checkpoints. Interrupted jobs repeat only the unfinished chunk.
            var updated = source
            var offset = source.transcriptionOffset ?? source.segments.map(\.end).max() ?? 0
            guard let locale = await SpeechTranscriber.installedLocales.first(where: {
                $0.language.languageCode == Locale(identifier: source.language).language.languageCode
            }) else {
                throw ContextAuthoringError.message("The speech model for this language is no longer installed. Import subtitles or install the voice model before trying again.")
            }
            while offset < duration {
                try Task.checkCancellation()
                let end = min(duration, offset + 30)
                let data = try await ContextMediaPreparation.clip(url: sourceURL, kind: .audio, start: offset, end: end)
                let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("context-transcribe-\(UUID()).m4a")
                defer { try? FileManager.default.removeItem(at: audioURL) }
                try data.write(to: audioURL)
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let file = try AVAudioFile(forReading: audioURL)
                let results = transcriber.results
                let chunkStart = offset
                let reading = Task { () throws -> [ContextTranscriptSegment] in
                    var segments: [ContextTranscriptSegment] = []
                    for try await result in results where result.isFinal {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            segments.append(.init(text: text, start: chunkStart + result.range.start.seconds,
                                                  end: min(end, chunkStart + CMTimeRangeGetEnd(result.range).seconds)))
                        }
                    }
                    return segments
                }
                do {
                    if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
                    else { await analyzer.cancelAndFinishNow() }
                    let segments = try await reading.value
                    let previous = updated
                    updated.segments += segments
                    // A silent chunk still needs a checkpoint to avoid reprocessing it after cancellation.
                    updated.transcriptionOffset = end
                    try await library.save(updated, replacing: previous)
                    offset = end
                } catch {
                    reading.cancel(); await analyzer.cancelAndFinishNow(); throw error
                }
            }
            let previous = updated
            updated.transcriptionComplete = true
            try await library.save(updated, replacing: previous)
        }
        #endif
    }
}
