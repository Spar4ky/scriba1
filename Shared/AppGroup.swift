import Foundation

/// Wspólny kontener (App Group) aplikacji Skryba i rozszerzenia udostępniania.
/// Rozszerzenie odkłada tu nagrania z Dyktafonu, a aplikacja je stąd zabiera.
///
/// Programy instalujące aplikację (Sideloadly, AltStore, SideStore) potrafią zmienić nazwę
/// grupy – np. dopisać identyfikator zespołu. Dlatego sprawdzamy kilka źródeł
/// i wybieramy tę grupę, do której system faktycznie dał dostęp.
enum AppGroup {
    static let infoPlistKey = "SkrybaAppGroupID"

    /// Grupa działająca w tej instalacji (nil = brak wspólnego kontenera).
    static let identifier: String? = {
        let fileManager = FileManager.default
        for candidate in candidates() where fileManager.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
            return candidate
        }
        return nil
    }()

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

    /// Grupy warte sprawdzenia – od najbardziej prawdopodobnej.
    static func candidates() -> [String] {
        var result: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("group."), !trimmed.contains("$("), !result.contains(trimmed) else { return }
            result.append(trimmed)
        }

        let configured = (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        add(configured)

        // AltStore i SideStore zapisują faktyczne nazwy grup w Info.plist.
        let altStoreGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        for group in altStoreGroups {
            add(group)
        }

        // Pozostałe programy: grupy wpisane w profil, którym podpisano aplikację.
        let profileGroups = ProvisioningProfile.applicationGroups()
        if !configured.isEmpty {
            for group in profileGroups where group.hasPrefix(configured) {
                add(group)
            }
        }
        for group in profileGroups {
            add(group)
        }
        return result
    }

    /// Krótki opis do ekranu diagnostyki.
    static var statusDescription: String {
        if let identifier {
            return "działa (\(identifier))"
        }
        let checked = candidates()
        if checked.isEmpty {
            return "brak – nagrania idą przez folder Skryba"
        }
        return "brak dostępu do: " + checked.joined(separator: ", ")
    }
}

/// Uprawnienia zapisane w profilu, którym podpisano aplikację (embedded.mobileprovision).
enum ProvisioningProfile {
    static func applicationGroups() -> [String] {
        entitlements()?["com.apple.security.application-groups"] as? [String] ?? []
    }

    static func entitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        // Profil to podpisana koperta CMS – sam plist leży w środku jako zwykły tekst.
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plist = object as? [String: Any] else {
            return nil
        }
        return plist["Entitlements"] as? [String: Any]
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
            return "Brak wspólnego kontenera aplikacji (App Group)."
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
