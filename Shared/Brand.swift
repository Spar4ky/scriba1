import SwiftUI

/// Kolory i gradienty Skryby (wspólne dla aplikacji i rozszerzenia).
enum Brand {
    static let indigo = Color(red: 0.36, green: 0.36, blue: 0.965)
    static let violet = Color(red: 0.62, green: 0.30, blue: 0.94)
    static let orchid = Color(red: 0.80, green: 0.30, blue: 0.76)
    static let coral = Color(red: 1.0, green: 0.27, blue: 0.40)
    static let crimson = Color(red: 0.88, green: 0.09, blue: 0.36)
    static let night = Color(red: 0.05, green: 0.05, blue: 0.12)
    static let midnight = Color(red: 0.11, green: 0.09, blue: 0.27)
    static let dusk = Color(red: 0.22, green: 0.15, blue: 0.47)

    static var gradient: LinearGradient {
        LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var recordGradient: LinearGradient {
        LinearGradient(colors: [coral, crimson], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var nightGradient: LinearGradient {
        LinearGradient(colors: [night, midnight, dusk], startPoint: .top, endPoint: .bottom)
    }
}

/// Polska odmiana liczebników: 1 nagranie, 2 nagrania, 5 nagrań.
enum Plural {
    static func polish(_ count: Int, one: String, few: String, many: String) -> String {
        if count == 1 { return one }
        let mod10 = count % 10
        let mod100 = count % 100
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }

    static func words(_ count: Int) -> String {
        "\(count) " + polish(count, one: "słowo", few: "słowa", many: "słów")
    }

    static func recordings(_ count: Int) -> String {
        "\(count) " + polish(count, one: "nagranie", few: "nagrania", many: "nagrań")
    }
}
