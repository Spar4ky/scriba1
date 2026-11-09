import Foundation

/// Folder „Skryba” w aplikacji Pliki (to katalog Documents aplikacji).
/// Działa zawsze, także bez App Group: nagranie zapisane w tym folderze
/// Skryba sama doda do biblioteki i przepisze przy najbliższym otwarciu.
enum DropFolder {
    /// Ukryty znacznik – po nim rozszerzenie poznaje, że wskazano właściwy folder.
    static let markerName = ".skryba-folder"
    static let readmeName = "Wrzuć tu nagrania.txt"
    static let failedFolderName = "Nie udało się dodać"
    /// Plik w trakcie zapisu ma dopisek .part – aplikacja go pomija.
    static let partialExtension = "part"

    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "caf", "aif", "aiff", "aifc", "aac", "qta",
        "mov", "mp4", "m4v", "3gp", "flac"
    ]

    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Czy wskazany folder to folder Skryby?
    static func isSkrybaFolder(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.appendingPathComponent(markerName).path)
            || fileManager.fileExists(atPath: url.appendingPathComponent(readmeName).path)
    }

    /// Bezpieczna nazwa pliku z tytułu nagrania.
    static func fileName(for title: String?, ext: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var base = (title ?? "")
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") {
            base.removeFirst()
        }
        if base.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "pl_PL")
            formatter.dateFormat = "d MMM yyyy HH.mm"
            base = "Nagranie " + formatter.string(from: Date())
        }
        return String(base.prefix(80)) + "." + ext
    }

    /// Wolna ścieżka w folderze, np. „Wykład (2).m4a”.
    static func uniqueURL(in folder: URL, fileName: String) -> URL {
        let fileManager = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path)
                || fileManager.fileExists(atPath: candidate.path + "." + partialExtension) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    /// Kopiuje nagranie do folderu tak, żeby aplikacja nigdy nie zobaczyła go w połowie zapisu.
    @discardableResult
    static func deliver(fileAt source: URL, title: String?, into folder: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let destination = uniqueURL(in: folder, fileName: fileName(for: title, ext: ext))
        let partial = destination.appendingPathExtension(partialExtension)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: partial)
        try fileManager.copyItem(at: source, to: partial)
        try fileManager.moveItem(at: partial, to: destination)
        return destination
    }

    // MARK: - Strona aplikacji

    /// Katalog Documents – w aplikacji Pliki widoczny jako „Skryba”.
    static var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static let readmeText = """
    Zapisz tu nagranie, a Skryba sama je doda i zrobi transkrypcję, gdy ją otworzysz.

    Z Dyktafonu: wybierz nagranie → Udostępnij → Zachowaj w Plikach → \(DeviceNames.onMyDevice) → Skryba → Zapisz.

    Możesz też przeciągać tu pliki z komputera (iTunes albo Finder → Udostępnianie plików → Skryba).
    """

    /// Tworzy znacznik i instrukcję, dzięki którym folder pojawia się w aplikacji Pliki.
    static func prepare() {
        guard let folder = documentsURL else { return }
        let fileManager = FileManager.default
        let marker = folder.appendingPathComponent(markerName)
        if !fileManager.fileExists(atPath: marker.path) {
            fileManager.createFile(atPath: marker.path, contents: Data("Skryba".utf8))
        }
        let readme = folder.appendingPathComponent(readmeName)
        if !fileManager.fileExists(atPath: readme.path) {
            try? readmeText.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Nagrania czekające w folderze (najstarsze pierwsze).
    static func pendingFiles() -> [URL] {
        guard let folder = documentsURL else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        let files = items.filter { url in
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isFile && isAudioFile(url)
        }
        return files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left < right
        }
    }

    /// Czy plik leży bezpośrednio w folderze Skryby?
    static func contains(_ url: URL) -> Bool {
        guard let folder = documentsURL else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return parent == folder.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Odkłada plik, którego nie dało się dodać, żeby nie próbować w kółko.
    static func moveToFailed(_ url: URL) {
        guard let folder = documentsURL else { return }
        let target = folder.appendingPathComponent(failedFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let destination = uniqueURL(in: target, fileName: url.lastPathComponent)
        try? FileManager.default.moveItem(at: url, to: destination)
    }
}

/// Zapamiętany przez rozszerzenie dostęp do folderu Skryby (gdy nie ma App Group).
enum DropFolderBookmark {
    private static let key = "skryba.dropFolderBookmark"

    @discardableResult
    static func save(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
            forget()
            return nil
        }
        if isStale {
            let accessing = url.startAccessingSecurityScopedResource()
            save(url)
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return url
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Nazwa urządzenia w tekstach (iPad / iPhone) w potrzebnych przypadkach.
enum DeviceNames {
    /// Identyfikator modelu, np. „iPad13,16” albo „iPhone16,2”.
    static let machineIdentifier: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let bytes = Mirror(reflecting: info.machine).children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(bitPattern: value)
        }
        return String(decoding: bytes, as: UTF8.self)
    }()

    static let isPad: Bool = machineIdentifier.hasPrefix("iPad")

    /// „iPad” / „iPhone”
    static var nominative: String { isPad ? "iPad" : "iPhone" }
    /// „iPada” / „iPhone’a” (np. „z tego iPada”)
    static var genitive: String { isPad ? "iPada" : "iPhone’a" }
    /// „iPadzie” / „iPhonie” (np. „na tym iPadzie”)
    static var locative: String { isPad ? "iPadzie" : "iPhonie" }
    /// Nazwa lokalizacji w aplikacji Pliki.
    static var onMyDevice: String { isPad ? "Na moim iPadzie" : "Na moim iPhonie" }
}
