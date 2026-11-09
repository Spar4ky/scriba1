import CoreML
import Foundation
import Observation
import WhisperKit

/// Whisper uruchamiany w całości na urządzeniu (WhisperKit, Core ML / Neural Engine).
/// Działa bez internetu – sieć jest potrzebna tylko raz, do pobrania modelu.
/// Nagranie jest dzielone na ok. minutowe fragmenty cięte w ciszy, dzięki czemu
/// zużycie pamięci jest stałe, a przerwana transkrypcja wznawia się od ostatniego fragmentu.
/// Działa też w tle: bez karty graficznej, oszczędniej i z przerwami dla procesora.
enum WhisperLocalEngine {
    static func transcribe(
        job: TranscriptionJob,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptSegment] {
        let variant = job.model.isEmpty ? WhisperModels.accurate : job.model
        events(.stage("Przygotowuję model Whisper…"))
        let kit = try await WhisperModelHost.shared.pipeline(for: variant)
        try Task.checkCancellation()
        events(.engine("Whisper na \(DeviceNames.locative) · \(WhisperModels.name(for: variant))"))
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
        // Fragmenty ok. 1 min: częste punkty kontrolne, a przy wyjściu z aplikacji
        // dokończenie bieżącego fragmentu trwa krótko (iOS pilnuje zużycia procesora w tle).
        let chunker = SilenceChunker(reader: reader, startAt: job.resumeFrom, minDuration: 55, maxDuration: 75)
        let total = max(reader.duration, 1)
        var segments = job.partialSegments
        events(.progress(min(1, job.resumeFrom / total)))
        if !segments.isEmpty { events(.partial(segments)) }

        let started = Date()
        var processed = 0.0
        var chunkCount = 0
        while true {
            try Task.checkCancellation()
            // W tle: przy nagrywaniu ustępujemy mu miejsca, a gdy system nie pozwala – czekamy na powrót.
            try await BackgroundGate.checkpoint(events: events)
            let limit = AppActivity.shared.isInBackground ? BackgroundGate.backgroundChunkLimit : nil
            guard let chunk = try chunker.next(limit: limit) else { break }
            chunkCount += 1
            events(.stage("Transkrybuję \(TranscriptFormatter.clock(chunk.start)) z \(TranscriptFormatter.clock(total))…"))
            if chunk.duration >= 0.5 && AudioMath.peakLevel(of: chunk.samples) > -50 {
                let results = try await transcribeChunk(chunk, kit: kit, options: options, events: events)
                segments.append(contentsOf: convert(results, offset: chunk.start, chunkEnd: chunk.end))
            }
            processed += chunk.duration
            if chunkCount == 1 || chunkCount % 15 == 0 {
                let speed = processed / max(Date().timeIntervalSince(started), 0.1)
                let place = AppActivity.shared.isInBackground ? " (w tle)" : ""
                DiagnosticsLog.add("Gotowe \(TranscriptFormatter.clock(chunk.end)) z \(TranscriptFormatter.clock(total))\(place) · szybkość \(String(format: "%.1f", speed))× czasu nagrania")
            }
            events(.checkpoint(segments, chunk.end))
            events(.progress(min(1, chunk.end / total)))
        }
        events(.stage(nil))
        return segments
    }

    /// Jeden fragment. W tle pracujemy oszczędniej (jeden wątek, przerwy dla procesora),
    /// a gdy system odmówi pracy w tle – czekamy na powrót do Skryby i powtarzamy fragment.
    private static func transcribeChunk(
        _ chunk: PCMChunk,
        kit: WhisperKit,
        options: DecodingOptions,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptionResult] {
        var attempts = 0
        while true {
            let inBackground = AppActivity.shared.isInBackground
            var chunkOptions = options
            if inBackground {
                chunkOptions.concurrentWorkerCount = 1
            }
            BackgroundWorkGuard.chunkStarted()
            let cpuStart = ProcessCPU.seconds()
            let wallStart = Date()
            do {
                let results = try await kit.transcribe(audioArray: chunk.samples, decodeOptions: chunkOptions)
                BackgroundWorkGuard.chunkFinished(succeeded: true, ranInBackground: inBackground)
                if AppActivity.shared.isInBackground {
                    await BackgroundGate.throttle(
                        cpuUsed: ProcessCPU.seconds() - cpuStart,
                        wall: Date().timeIntervalSince(wallStart)
                    )
                }
                return results
            } catch {
                BackgroundWorkGuard.chunkFinished(succeeded: false, ranInBackground: inBackground)
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                let backgroundRelated = inBackground || AppActivity.shared.isInBackground
                guard backgroundRelated, attempts < 3 else {
                    throw error
                }
                attempts += 1
                BackgroundWorkGuard.recordFailure("Fragment nie przeszedł w tle (\(error.localizedDescription))", definite: true)
                events(.waitingForForeground(true))
                await BackgroundGate.waitForForeground()
                events(.waitingForForeground(false))
                try Task.checkCancellation()
            }
        }
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

// MARK: - Stan modelu (dla interfejsu)

/// Co się teraz dzieje z modelem Whisper – widoczne na karcie transkrypcji i w Ustawieniach.
@MainActor
@Observable
final class ModelStatus {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case preparing(firstTime: Bool)
        case ready
        case failed(String)
    }

    static let shared = ModelStatus()

    private(set) var variant: String?
    private(set) var phase: Phase = .idle
    /// Od kiedy trwa bieżący etap (do licznika czasu przy przygotowaniu modelu).
    private(set) var phaseStartedAt = Date()
    /// Numer najnowszego ładowania – wieści ze starszych (porzuconych) ładowań są pomijane.
    @ObservationIgnored private var latestGeneration = 0

    var isBusy: Bool {
        switch phase {
        case .downloading, .preparing:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    func set(_ newPhase: Phase, variant newVariant: String, generation: Int) {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        if variant != newVariant || !ModelStatus.sameKind(phase, newPhase) {
            phaseStartedAt = Date()
        }
        variant = newVariant
        phase = newPhase
    }

    /// Postęp pobierania (zaokrąglony do 1%, żeby nie odświeżać ekranu bez potrzeby).
    func reportDownload(_ fraction: Double, variant reported: String, generation: Int) {
        guard generation == latestGeneration, variant == reported, case .downloading(let current) = phase else { return }
        let rounded = (min(max(fraction, 0), 1) * 100).rounded() / 100
        if rounded > current {
            phase = .downloading(rounded)
        }
    }

    /// Po usunięciu modelu.
    func reset() {
        variant = nil
        phase = .idle
        phaseStartedAt = Date()
    }

    private static func sameKind(_ lhs: Phase, _ rhs: Phase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.downloading, .downloading), (.preparing, .preparing), (.ready, .ready), (.failed, .failed):
            return true
        default:
            return false
        }
    }
}

// MARK: - Pliki modeli

/// Modele trzymamy w Application Support – poza folderem „Skryba” widocznym w aplikacji Pliki.
enum WhisperStorage {
    static var baseURL: URL {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let url = support.appendingPathComponent("Whisper", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
        }
        return url
    }

    /// Starsza wersja zapisywała modele w Documents/huggingface (widoczne w Plikach).
    /// Przenosimy je w nowe miejsce i poprawiamy zapamiętane ścieżki.
    static func migrateIfNeeded(variants: [String]) {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let old = documents.appendingPathComponent("huggingface", isDirectory: true)
        guard fileManager.fileExists(atPath: old.path) else { return }

        let base = baseURL
        let oldModels = old.appendingPathComponent("models", isDirectory: true)
        let newModels = base.appendingPathComponent("models", isDirectory: true)
        var moved = false
        if fileManager.fileExists(atPath: oldModels.path) && !fileManager.fileExists(atPath: newModels.path) {
            moved = (try? fileManager.moveItem(at: oldModels, to: newModels)) != nil
        }
        try? fileManager.removeItem(at: old)

        let home = NSHomeDirectory()
        let oldPrefix = "Documents/huggingface/models/"
        let newPrefix = base.path.hasPrefix(home + "/")
            ? String(base.path.dropFirst(home.count + 1)) + "/models/"
            : nil
        for variant in variants {
            let key = WhisperModelHost.folderKey(for: variant)
            WhisperModelHost.resetPrepared(variant)
            guard let stored = UserDefaults.standard.string(forKey: key), stored.hasPrefix(oldPrefix) else { continue }
            if moved, let newPrefix {
                UserDefaults.standard.set(newPrefix + String(stored.dropFirst(oldPrefix.count)), forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        DiagnosticsLog.add(moved ? "Przeniesiono modele Whisper poza folder Plików" : "Usunięto stary folder modeli Whisper")
    }
}

/// Załadowany model – opakowany, żeby bezpiecznie przekazywać go między wątkami.
final class LoadedWhisper: @unchecked Sendable {
    let kit: WhisperKit
    let variant: String

    init(kit: WhisperKit, variant: String) {
        self.kit = kit
        self.variant = variant
    }
}

/// Trzyma załadowany model w pamięci między transkrypcjami, pobiera go i przygotowuje.
/// Równoczesne prośby o ten sam model czekają na jedno ładowanie.
actor WhisperModelHost {
    static let shared = WhisperModelHost()

    private var loaded: LoadedWhisper?
    private var inFlightVariant: String?
    private var inFlightTask: Task<LoadedWhisper, Error>?
    private var generation = 0

    func pipeline(for variant: String) async throws -> WhisperKit {
        if let loaded, loaded.variant == variant {
            return loaded.kit
        }
        if let task = inFlightTask, inFlightVariant == variant {
            return try await task.value.kit
        }

        // Inny model niż ładowany? Porzucamy stare ładowanie (pobieranie da się przerwać,
        // przygotowanie Core ML dokończy się w tle, a jego wynik zostanie pominięty).
        inFlightTask?.cancel()
        generation += 1
        let current = generation
        loaded = nil
        let task = Task<LoadedWhisper, Error> {
            try await WhisperModelHost.load(variant: variant, generation: current)
        }
        inFlightVariant = variant
        inFlightTask = task
        do {
            let result = try await task.value
            if generation == current {
                loaded = result
                inFlightTask = nil
                inFlightVariant = nil
            }
            return result.kit
        } catch {
            if generation == current {
                inFlightTask = nil
                inFlightVariant = nil
            }
            throw error
        }
    }

    func unload() {
        inFlightTask?.cancel()
        generation += 1
        loaded = nil
        inFlightTask = nil
        inFlightVariant = nil
    }

    // MARK: - Ładowanie

    private static func load(variant: String, generation: Int) async throws -> LoadedWhisper {
        let folder = try await ensureDownloaded(variant: variant, generation: generation)
        try Task.checkCancellation()
        let firstTime = !isPrepared(variant)
        await MainActor.run {
            ModelStatus.shared.set(.preparing(firstTime: firstTime), variant: variant, generation: generation)
        }
        DiagnosticsLog.add("Model \(WhisperModels.name(for: variant)): \(firstTime ? "pierwsze przygotowanie (Core ML dopasowuje model do procesora)" : "ładowanie do pamięci")")
        let started = Date()
        do {
            var config = WhisperKitConfig(modelFolder: folder.path)
            config.tokenizerFolder = WhisperStorage.baseURL
            config.computeOptions = WhisperModelHost.computeOptions
            config.load = false
            let kit = try await WhisperKit(config)
            try await kit.loadModels()
            markPrepared(variant)
            DiagnosticsLog.add("Model gotowy po \(Int(Date().timeIntervalSince(started))) s")
            await MainActor.run {
                ModelStatus.shared.set(.ready, variant: variant, generation: generation)
            }
            return LoadedWhisper(kit: kit, variant: variant)
        } catch {
            DiagnosticsLog.add("Błąd uruchamiania modelu po \(Int(Date().timeIntervalSince(started))) s: \(error.localizedDescription)")
            let failure = SkrybaError.modelLoadFailed(error.localizedDescription)
            let message = failure.errorDescription ?? error.localizedDescription
            await MainActor.run {
                ModelStatus.shared.set(.failed(message), variant: variant, generation: generation)
            }
            throw failure
        }
    }

    /// Bez karty graficznej: iOS nie pozwala używać GPU w tle (praca się przerywa,
    /// a nowsze systemy wręcz zamykają aplikację). Spektrogram liczy procesor,
    /// a enkoder i dekoder – Neural Engine (z procesorem jako zapasem).
    static var computeOptions: ModelComputeOptions {
        ModelComputeOptions(
            melCompute: .cpuOnly,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine,
            prefillCompute: .cpuOnly
        )
    }

    // MARK: - Pliki modelu

    static func folderKey(for variant: String) -> String {
        "skryba.whisperFolder.\(variant)"
    }

    private static func preparedKey(for variant: String) -> String {
        "skryba.whisperPrepared.\(variant)"
    }

    /// Czy model był już raz załadowany (wtedy kolejne ładowania trwają kilka sekund)?
    static func isPrepared(_ variant: String) -> Bool {
        UserDefaults.standard.bool(forKey: preparedKey(for: variant))
    }

    static func markPrepared(_ variant: String) {
        UserDefaults.standard.set(true, forKey: preparedKey(for: variant))
    }

    static func resetPrepared(_ variant: String) {
        UserDefaults.standard.removeObject(forKey: preparedKey(for: variant))
    }

    /// Folder z pobranym modelem albo nil, jeśli modelu jeszcze nie ma.
    /// Ścieżka jest zapisywana względem katalogu aplikacji (ten zmienia się przy aktualizacjach).
    static func localFolder(for variant: String) -> URL? {
        guard let relative = UserDefaults.standard.string(forKey: folderKey(for: variant)) else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
        let marker = url.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: marker.path) ? url : nil
    }

    static func isDownloaded(_ variant: String) -> Bool {
        localFolder(for: variant) != nil
    }

    private static func ensureDownloaded(variant: String, generation: Int) async throws -> URL {
        if let local = localFolder(for: variant) {
            return local
        }
        await MainActor.run {
            ModelStatus.shared.set(.downloading(0), variant: variant, generation: generation)
        }
        DiagnosticsLog.add("Pobieranie modelu \(WhisperModels.name(for: variant)) (\(variant))…")
        let started = Date()
        let url: URL
        do {
            url = try await WhisperKit.download(
                variant: variant,
                downloadBase: WhisperStorage.baseURL,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        ModelStatus.shared.reportDownload(fraction, variant: variant, generation: generation)
                    }
                }
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                DiagnosticsLog.add("Pobieranie modelu przerwane")
                throw CancellationError()
            }
            DiagnosticsLog.add("Błąd pobierania modelu: \(error.localizedDescription)")
            let failure = SkrybaError.modelDownloadFailed(SkrybaError.describe(error))
            let message = failure.errorDescription ?? error.localizedDescription
            await MainActor.run {
                ModelStatus.shared.set(.failed(message), variant: variant, generation: generation)
            }
            throw failure
        }
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home + "/") {
            UserDefaults.standard.set(String(path.dropFirst(home.count + 1)), forKey: folderKey(for: variant))
        }
        resetPrepared(variant)
        DiagnosticsLog.add("Model pobrany w \(Int(Date().timeIntervalSince(started))) s")
        return url
    }

    /// Usuwa pobrany model (zwalnia miejsce).
    static func delete(_ variant: String) {
        if let folder = localFolder(for: variant) {
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.removeObject(forKey: folderKey(for: variant))
        resetPrepared(variant)
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
