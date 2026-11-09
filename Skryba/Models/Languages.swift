import Foundation

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    static let defaultCode = "pl-PL"

    static let all: [LanguageOption] = [
        LanguageOption(code: "pl-PL", name: "Polski"),
        LanguageOption(code: "en-US", name: "English (US)"),
        LanguageOption(code: "en-GB", name: "English (UK)"),
        LanguageOption(code: "de-DE", name: "Deutsch"),
        LanguageOption(code: "es-ES", name: "Español"),
        LanguageOption(code: "fr-FR", name: "Français"),
        LanguageOption(code: "it-IT", name: "Italiano"),
        LanguageOption(code: "pt-BR", name: "Português (Brasil)"),
        LanguageOption(code: "nl-NL", name: "Nederlands"),
        LanguageOption(code: "cs-CZ", name: "Čeština"),
        LanguageOption(code: "uk-UA", name: "Українська"),
        LanguageOption(code: "ru-RU", name: "Русский")
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    /// Kod ISO-639-1 dla Whispera, np. „pl-PL” → „pl”.
    static func whisperCode(for code: String) -> String {
        let prefix = code.split(separator: "-").first.map(String.init) ?? "pl"
        return prefix.lowercased()
    }
}
