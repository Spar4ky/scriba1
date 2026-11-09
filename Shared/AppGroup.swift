import Foundation

/// Wspólny kontener (App Group) aplikacji Skryba i rozszerzenia „Transkrybuj”.
/// Rozszerzenie odkłada tu nagrania z Dyktafonu, a aplikacja je stąd zabiera.
enum AppGroup {
    static let infoPlistKey = "SkrybaAppGroupID"

    static var identifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static var containerURL: URL? {
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var inboxURL: URL? {
        guard let container = containerURL else { return nil }
        let url = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Opis pliku przekazanego przez rozszerzenie.
struct InboxManifest: Codable {
    var id: UUID
    var audioFileName: String
    var title: String?
    var createdAt: Date
}

struct InboxItem {
    let manifest: InboxManifest
    let manifestURL: URL
    let audioURL: URL
}

enum InboxError: LocalizedError {
    case noSharedContainer

    var errorDescription: String? {
        switch self {
        case .noSharedContainer:
            return "Brak wspólnego kontenera aplikacji (App Group). Udostępnij nagranie opcją „Skryba” albo sprawdź podpisywanie obu targetów w Xcode."
        }
    }
}

enum Inbox {
    /// Kopiuje plik do skrzynki i zapisuje manifest. Manifest powstaje na końcu,
    /// więc aplikacja nigdy nie zobaczy niedokończonego pliku.
    @discardableResult
    static func store(fileAt source: URL, title: String?) throws -> InboxManifest {
        guard let inbox = AppGroup.inboxURL else { throw InboxError.noSharedContainer }
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let audioName = "\(id.uuidString).\(ext)"
        let destination = inbox.appendingPathComponent(audioName)
        try FileManager.default.copyItem(at: source, to: destination)
        let manifest = InboxManifest(id: id, audioFileName: audioName, title: title, createdAt: Date())
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: inbox.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        return manifest
    }

    static func pendingItems() -> [InboxItem] {
        guard let inbox = AppGroup.inboxURL else { return [] }
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var items: [InboxItem] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? decoder.decode(InboxManifest.self, from: data) else { continue }
            let audio = inbox.appendingPathComponent(manifest.audioFileName)
            guard fileManager.fileExists(atPath: audio.path) else {
                try? fileManager.removeItem(at: file)
                continue
            }
            items.append(InboxItem(manifest: manifest, manifestURL: file, audioURL: audio))
        }
        return items.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    static func remove(_ item: InboxItem) {
        try? FileManager.default.removeItem(at: item.audioURL)
        try? FileManager.default.removeItem(at: item.manifestURL)
    }
}
