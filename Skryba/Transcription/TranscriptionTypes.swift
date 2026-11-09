import Foundation

/// Wszystko, czego silnik potrzebuje do transkrypcji jednego nagrania.
struct TranscriptionJob: Sendable {
    var recordingID: UUID
    var audioURL: URL
    var language: String
    var engine: EngineChoice
    var model: String
    var farField: Bool
    var vocabulary: [String]
    var resumeFrom: Double
    var partialSegments: [TranscriptSegment]
    var checkpointKey: String

    var whisperLanguage: String { Languages.whisperCode(for: language) }
}

/// Zdarzenia raportowane przez silnik w trakcie pracy.
enum TranscriptionEvent: Sendable {
    /// Nazwa użytego silnika (do wyświetlenia).
    case engine(String)
    /// Opis bieżącego etapu, np. pobieranie modelu (nil = brak).
    case stage(String?)
    /// Postęp 0…1.
    case progress(Double)
    /// Podgląd dotychczasowego tekstu.
    case partial([TranscriptSegment])
    /// Punkt kontrolny: wyniki do danej sekundy (do wznowienia po przerwie).
    case checkpoint([TranscriptSegment], Double)
}

enum SkrybaError: LocalizedError {
    case languageNotSupported(String)
    case appleServiceUnavailable
    case speechPermissionDenied
    case modelDownloadFailed(String)
    case modelLoadFailed(String)
    case api(String)
    case timeout
    case audioUnreadable

    var errorDescription: String? {
        switch self {
        case .languageNotSupported(let name):
            return "Rozpoznawanie mowy Apple nie obsługuje języka: \(name). Wybierz w Ustawieniach silnik Whisper."
        case .appleServiceUnavailable:
            return "Rozpoznawanie mowy Apple jest teraz niedostępne. Sprawdź połączenie z internetem i czy Dyktowanie jest włączone (Ustawienia → Ogólne → Klawiatura)."
        case .speechPermissionDenied:
            return "Brak zgody na rozpoznawanie mowy. Włącz ją w Ustawieniach iPhone’a → Skryba."
        case .modelDownloadFailed(let reason):
            return "Nie udało się pobrać modelu Whisper (jednorazowo potrzebny internet, najlepiej Wi-Fi). \(reason)"
        case .modelLoadFailed(let reason):
            return "Nie udało się uruchomić modelu Whisper. Jeśli to starszy iPhone, wybierz w Ustawieniach model „Szybki”. \(reason)"
        case .api(let message):
            return message
        case .timeout:
            return "Serwer zbyt długo nie odpowiadał. Spróbuj ponownie – transkrypcja wznowi się od miejsca przerwania."
        case .audioUnreadable:
            return "Nie udało się odczytać pliku dźwiękowego."
        }
    }

    /// Czytelny komunikat dla dowolnego błędu.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotConnectToHost, .cannotFindHost:
                return "Brak połączenia z internetem. Połącz się i dotknij „Spróbuj ponownie”."
            case .timedOut:
                return "Przekroczono czas oczekiwania na serwer. Spróbuj ponownie."
            default:
                return "Błąd sieci: \(urlError.localizedDescription)"
            }
        }
        if let known = error as? SkrybaError, let description = known.errorDescription {
            return description
        }
        if let known = error as? PCMError, let description = known.errorDescription {
            return description
        }
        if let known = error as? AudioImportError, let description = known.errorDescription {
            return description
        }
        let nsError = error as NSError
        let speechDomains = ["kAFAssistantErrorDomain", "kLSRErrorDomain", "SFSpeechErrorDomain"]
        if speechDomains.contains(nsError.domain) {
            return "Rozpoznawanie mowy Apple zgłosiło błąd (\(nsError.code)). Sprawdź internet i czy Dyktowanie jest włączone (Ustawienia → Ogólne → Klawiatura). Możesz też wybrać silnik Whisper (działa bez internetu)."
        }
        return error.localizedDescription
    }
}
