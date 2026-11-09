import Foundation
import WhisperKit

/// Whisper uruchamiany w całości na iPhonie (WhisperKit, Core ML / Neural Engine).
/// Działa bez internetu – sieć jest potrzebna tylko raz, do pobrania modelu.
/// Nagranie jest dzielone na ok. 2-minutowe fragmenty cięte w ciszy, dzięki czemu
/// zużycie pamięci jest stałe, a przerwana transkrypcja wznawia się od ostatniego fragmentu.
enum WhisperLocalEngine {
    static func transcribe(
        job: TranscriptionJob,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptSegment] {
        let variant = job.model.isEmpty ? WhisperModels.accurate : job.model
        let kit = try await WhisperModelHost.shared.pipeline(for: variant, events: events)
        events(.engine("Whisper na iPhonie · \(WhisperModels.name(for: variant))"))
        events(.stage(nil))

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = job.whisperLanguage
        options.temperature = 0
        options.usePrefillPrompt = true
        options.detectLanguage = false
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.chunkingStrategy = .vad

        let reader = try PCMReader(url: job.audioURL)
        let chunker = SilenceChunker(reader: reader, startAt: job.resumeFrom, minDuration: 90, maxDuration: 120)
        let total = max(reader.duration, 1)
        let totalChunks = max(1, Int((total / 110).rounded(.up)))
        var segments = job.partialSegments
        events(.progress(min(1, job.resumeFrom / total)))
        if !segments.isEmpty { events(.partial(segments)) }

        while let chunk = try chunker.next() {
            try Task.checkCancellation()
            let index = min(totalChunks, Int((chunk.start / 110).rounded(.down)) + 1)
            events(.stage("Transkrybuję fragment \(index) z ok. \(totalChunks)…"))
            if chunk.duration >= 0.5 && AudioMath.peakLevel(of: chunk.samples) > -50 {
                let results = try await kit.transcribe(audioArray: chunk.samples, decodeOptions: options)
                segments.append(contentsOf: convert(results, offset: chunk.start, chunkEnd: chunk.end))
            }
            events(.checkpoint(segments, chunk.end))
            events(.progress(min(1, chunk.end / total)))
        }
        events(.stage(nil))
        return segments
    }

    private static func convert(_ results: [TranscriptionResult], offset: Double, chunkEnd: Double) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        for result in results {
            var fromSegments: [TranscriptSegment] = []
            for segment in result.segments {
                let text = clean(segment.text)
                guard !text.isEmpty else { continue }
                if Hallucinations.isLikely(
                    text: text,
                    noSpeechProb: Double(segment.noSpeechProb),
                    avgLogprob: Double(segment.avgLogprob),
                    compressionRatio: Double(segment.compressionRatio)
                ) {
                    continue
                }
                fromSegments.append(TranscriptSegment(
                    start: offset + Double(segment.start),
                    end: offset + Double(segment.end),
                    text: text
                ))
            }
            if fromSegments.isEmpty && result.segments.isEmpty {
                let text = clean(result.text)
                if !text.isEmpty && !Hallucinations.isKnownPhrase(text) {
                    fromSegments.append(TranscriptSegment(start: offset, end: chunkEnd, text: text))
                }
            }
            output.append(contentsOf: fromSegments)
        }
        return output
    }

    /// Usuwa ewentualne tokeny specjalne typu <|pl|>, <|0.00|>.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Trzyma załadowany model w pamięci między transkrypcjami i zarządza pobieraniem.
actor WhisperModelHost {
    static let shared = WhisperModelHost()

    private var kit: WhisperKit?
    private var loadedVariant: String?

    func pipeline(
        for variant: String,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> WhisperKit {
        if let kit, loadedVariant == variant {
            return kit
        }
        kit = nil
        loadedVariant = nil

        let folder = try await WhisperModelHost.ensureDownloaded(variant: variant) { fraction in
            let percent = Int((fraction * 100).rounded())
            events(.stage("Pobieranie modelu Whisper (jednorazowo)… \(percent)%"))
        }
        events(.stage("Przygotowuję model – za pierwszym razem może to potrwać kilka minut…"))
        do {
            let config = WhisperKitConfig(modelFolder: folder.path)
            let newKit = try await WhisperKit(config)
            kit = newKit
            loadedVariant = variant
            return newKit
        } catch {
            throw SkrybaError.modelLoadFailed(error.localizedDescription)
        }
    }

    func unload() {
        kit = nil
        loadedVariant = nil
    }

    // MARK: - Pliki modelu

    private static func defaultsKey(for variant: String) -> String {
        "skryba.whisperFolder.\(variant)"
    }

    /// Folder z pobranym modelem albo nil, jeśli modelu jeszcze nie ma.
    /// Ścieżka jest zapisywana względem katalogu aplikacji (ten zmienia się przy aktualizacjach).
    static func localFolder(for variant: String) -> URL? {
        guard let relative = UserDefaults.standard.string(forKey: defaultsKey(for: variant)) else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
        let marker = url.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: marker.path) ? url : nil
    }

    static func isDownloaded(_ variant: String) -> Bool {
        localFolder(for: variant) != nil
    }

    static func ensureDownloaded(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let local = localFolder(for: variant) {
            return local
        }
        let url: URL
        do {
            url = try await WhisperKit.download(variant: variant, progressCallback: { value in
                progress(value.fractionCompleted)
            })
        } catch {
            throw SkrybaError.modelDownloadFailed(error.localizedDescription)
        }
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home + "/") {
            UserDefaults.standard.set(String(path.dropFirst(home.count + 1)), forKey: defaultsKey(for: variant))
        }
        return url
    }

    /// Usuwa pobrany model (zwalnia miejsce).
    static func delete(_ variant: String) {
        if let folder = localFolder(for: variant) {
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey(for: variant))
    }
}

/// Whisper potrafi „dopowiadać” typowe zdania w ciszy (np. podziękowania za obejrzenie).
enum Hallucinations {
    private static let phrases = [
        "napisy stworzone przez społeczność amara.org",
        "napisy wykonane przez społeczność amara.org",
        "napisy przygotowane przez społeczność amara.org",
        "dziękuję za obejrzenie",
        "dzięki za obejrzenie",
        "zapraszam do subskrypcji",
        "subskrybujcie kanał",
        "thank you for watching",
        "thanks for watching",
        "subtitles by the amara.org community"
    ]

    static func isLikely(text: String, noSpeechProb: Double, avgLogprob: Double, compressionRatio: Double) -> Bool {
        if compressionRatio > 2.6 { return true }
        if noSpeechProb > 0.6 && avgLogprob < -1.0 { return true }
        return isKnownPhrase(text)
    }

    static func isKnownPhrase(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        return phrases.contains { phrase in
            normalized == phrase || (normalized.hasPrefix(phrase) && normalized.count <= phrase.count + 12)
        }
    }
}
