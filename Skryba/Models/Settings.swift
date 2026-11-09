import Foundation

/// Silnik transkrypcji wybierany w Ustawieniach.
enum EngineChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case whisper
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisper: return "Whisper na iPhonie (zalecany)"
        case .apple: return "Rozpoznawanie mowy Apple"
        }
    }
}

/// Klucze UserDefaults – te same używa @AppStorage w widokach.
enum SettingsKey {
    static let language = "skryba.language"
    static let engine = "skryba.engine"
    static let whisperModel = "skryba.whisperModel"
    static let farField = "skryba.farField"
    static let autoCopy = "skryba.autoCopy"
    static let copyTimestamps = "skryba.copyTimestamps"
    static let vocabulary = "skryba.vocabulary"
}

enum SettingsDefault {
    static let language = Languages.defaultCode
    static let engine = EngineChoice.whisper
    /// iPhone’y z min. 6 GB RAM dostają dokładny model, starsze – lżejszy.
    static let whisperModel = ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
        ? WhisperModels.accurate
        : WhisperModels.fast
    static let farField = true
    static let autoCopy = false
    static let copyTimestamps = false
    static let vocabulary = ""
}

/// Migawka ustawień – bezpieczna do użycia poza wątkiem głównym.
struct SettingsSnapshot: Sendable {
    var language: String
    var engine: EngineChoice
    var whisperModel: String
    var farField: Bool
    var autoCopy: Bool
    var copyTimestamps: Bool
    var vocabulary: String

    static func current() -> SettingsSnapshot {
        let defaults = UserDefaults.standard
        return SettingsSnapshot(
            language: defaults.string(forKey: SettingsKey.language) ?? SettingsDefault.language,
            engine: EngineChoice(rawValue: defaults.string(forKey: SettingsKey.engine) ?? "") ?? SettingsDefault.engine,
            whisperModel: defaults.string(forKey: SettingsKey.whisperModel) ?? SettingsDefault.whisperModel,
            farField: defaults.object(forKey: SettingsKey.farField) as? Bool ?? SettingsDefault.farField,
            autoCopy: defaults.object(forKey: SettingsKey.autoCopy) as? Bool ?? SettingsDefault.autoCopy,
            copyTimestamps: defaults.object(forKey: SettingsKey.copyTimestamps) as? Bool ?? SettingsDefault.copyTimestamps,
            vocabulary: defaults.string(forKey: SettingsKey.vocabulary) ?? SettingsDefault.vocabulary
        )
    }

    func model(for engine: EngineChoice) -> String {
        switch engine {
        case .apple: return ""
        case .whisper: return whisperModel
        }
    }

    /// Słownik przedmiotu: terminy rozdzielone przecinkami lub nowymi liniami.
    var vocabularyList: [String] {
        let parts = vocabulary
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(parts.prefix(100))
    }
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
}

/// Modele Whisper uruchamiane na iPhonie (pobierane jednorazowo z Hugging Face).
enum WhisperModels {
    static let accurate = "openai_whisper-large-v3-v20240930_626MB"
    static let fast = "openai_whisper-small"

    static let all: [ModelOption] = [
        ModelOption(id: accurate, name: "Dokładny", detail: "Large v3 · ok. 630 MB · najlepszy dla polskiego"),
        ModelOption(id: fast, name: "Szybki", detail: "Small · ok. 250 MB · 3× szybszy, mniej dokładny")
    ]

    static func name(for id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}
