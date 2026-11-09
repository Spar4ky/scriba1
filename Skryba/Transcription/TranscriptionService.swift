import Foundation
import Speech

/// Wybiera silnik i uruchamia transkrypcję.
enum TranscriptionService {
    static func run(
        _ job: TranscriptionJob,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptSegment] {
        switch job.engine {
        case .whisper:
            return try await WhisperLocalEngine.transcribe(job: job, events: events)
        case .apple:
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                if let kind = await AnalyzerEngine.resolve(languageCode: job.language) {
                    do {
                        return try await AnalyzerEngine.transcribe(job: job, kind: kind, events: events)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw error }
                        guard LegacyAppleEngine.canHandle(language: job.language) else { throw error }
                        events(.stage("Przełączam na klasyczne rozpoznawanie mowy Apple…"))
                        var fallback = job
                        fallback.resumeFrom = 0
                        fallback.partialSegments = []
                        return try await LegacyAppleEngine.transcribe(job: fallback, events: events)
                    }
                }
            }
            #endif
            return try await LegacyAppleEngine.transcribe(job: job, events: events)
        }
    }
}

/// Opis tego, co Apple potrafi na tym iPhonie dla wybranego języka (do Ustawień).
enum EngineDiagnostics {
    enum Quality: Sendable {
        case best
        case good
        case limited
        case unavailable
    }

    struct Report: Sendable, Equatable {
        let title: String
        let detail: String
        let quality: Quality
    }

    static func appleReport(for language: String) async -> Report {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let kind = await AnalyzerEngine.resolve(languageCode: language) {
                switch kind {
                case .speech:
                    return Report(
                        title: "Model mowy Apple na iPhonie",
                        detail: "Działa offline, bez limitu długości i dobrze radzi sobie z wykładami.",
                        quality: .best
                    )
                case .dictation:
                    return Report(
                        title: "Dyktowanie Apple na iPhonie",
                        detail: "Działa offline. Najlepiej sprawdza się przy wyraźnej mowie.",
                        quality: .good
                    )
                }
            }
        }
        #endif
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            return Report(
                title: "Apple nie obsługuje tego języka",
                detail: "Wybierz silnik Whisper na iPhonie.",
                quality: .unavailable
            )
        }
        if recognizer.supportsOnDeviceRecognition {
            return Report(
                title: "Dyktowanie Apple na iPhonie",
                detail: "Działa offline. Nagranie jest przetwarzane we fragmentach ok. 1 minuty.",
                quality: .good
            )
        }
        return Report(
            title: "Dyktowanie Apple przez internet",
            detail: "Działa bez konfiguracji, ale wymaga internetu i radzi sobie przeciętnie z mową z dystansu. Do polskich wykładów zdecydowanie lepszy jest Whisper na iPhonie.",
            quality: .limited
        )
    }
}
