#if compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

/// Nowe API Apple z iOS 26 (SpeechAnalyzer): działa w całości na iPhonie,
/// bez limitu długości nagrania. SpeechTranscriber obsługuje kilkanaście języków,
/// DictationTranscriber – języki dyktowania dostępne offline.
@available(iOS 26.0, *)
enum AnalyzerEngine {
    enum Kind: Sendable {
        case speech(Locale)
        case dictation(Locale)
    }

    /// Najlepszy dostępny moduł Apple dla danego języka (albo nil).
    static func resolve(languageCode: String) async -> Kind? {
        let requested = Locale(identifier: languageCode)
        if await SpeechTranscriber.isAvailable {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                return .speech(locale)
            }
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            return .dictation(locale)
        }
        return nil
    }

    static func transcribe(
        job: TranscriptionJob,
        kind: Kind,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptSegment] {
        let audioFile = try AVAudioFile(forReading: job.audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let duration = sampleRate > 0 ? max(Double(audioFile.length) / sampleRate, 1) : 1

        switch kind {
        case .speech(let locale):
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            try await installAssets(for: [transcriber], events: events)
            events(.engine("Apple · model mowy na iPhonie"))
            events(.stage(nil))
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            async let collected = collectSpeech(from: transcriber, duration: duration, events: events)
            try await analyze(audioFile, with: analyzer)
            let segments = try await collected
            events(.progress(1))
            return segments

        case .dictation(let locale):
            let preset = DictationTranscriber.Preset.progressiveLongDictation
            let hints = job.farField ? preset.contentHints.union([.farField]) : preset.contentHints
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: hints,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions,
                attributeOptions: preset.attributeOptions
            )
            try await installAssets(for: [transcriber], events: events)
            events(.engine("Apple · dyktowanie na iPhonie"))
            events(.stage(nil))
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            async let collected = collectDictation(from: transcriber, duration: duration, events: events)
            try await analyze(audioFile, with: analyzer)
            let segments = try await collected
            events(.progress(1))
            return segments
        }
    }

    // MARK: - Prywatne

    private static func analyze(_ audioFile: AVAudioFile, with analyzer: SpeechAnalyzer) async throws {
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func installAssets(
        for modules: [any SpeechModule],
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let title = "Pobieranie modelu mowy (jednorazowo)…"
        events(.stage(title))
        let progress = request.progress
        let monitor = Task {
            while !Task.isCancelled {
                let percent = Int((progress.fractionCompleted * 100).rounded())
                events(.stage("\(title) \(percent)%"))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        events(.stage(nil))
    }

    private static func collectSpeech(
        from transcriber: SpeechTranscriber,
        duration: Double,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var lastPreview = Date.distantPast
        for try await result in transcriber.results {
            guard result.isFinal, let segment = makeSegment(text: result.text, range: result.range) else { continue }
            segments.append(segment)
            events(.progress(min(0.99, segment.end / duration)))
            if Date().timeIntervalSince(lastPreview) > 1.5 {
                lastPreview = Date()
                events(.partial(segments))
            }
        }
        return segments
    }

    private static func collectDictation(
        from transcriber: DictationTranscriber,
        duration: Double,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var lastPreview = Date.distantPast
        for try await result in transcriber.results {
            guard result.isFinal, let segment = makeSegment(text: result.text, range: result.range) else { continue }
            segments.append(segment)
            events(.progress(min(0.99, segment.end / duration)))
            if Date().timeIntervalSince(lastPreview) > 1.5 {
                lastPreview = Date()
                events(.partial(segments))
            }
        }
        return segments
    }

    private static func makeSegment(text: AttributedString, range: CMTimeRange) -> TranscriptSegment? {
        let string = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        let start = range.start.seconds
        let end = range.end.seconds
        let safeStart = start.isFinite ? max(0, start) : 0
        let safeEnd = end.isFinite ? max(safeStart, end) : safeStart
        return TranscriptSegment(start: safeStart, end: safeEnd, text: string)
    }
}
#endif
