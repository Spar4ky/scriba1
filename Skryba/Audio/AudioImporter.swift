import AVFoundation
import Foundation

enum AudioImportError: LocalizedError {
    case unsupported
    case exportFailed(String?)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Ten plik nie zawiera obsługiwanej ścieżki dźwiękowej."
        case .exportFailed(let reason):
            if let reason { return "Nie udało się przekonwertować pliku: \(reason)" }
            return "Nie udało się przekonwertować pliku."
        }
    }
}

/// Dodaje plik audio/wideo do biblioteki. Typowe formaty są kopiowane bez zmian,
/// a pozostałe (np. .qta z Dyktafonu, .mov, .mp4) konwertowane do .m4a.
enum AudioImporter {
    private static let directExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aif", "aiff", "aac"]

    /// `destinationBase` to docelowa ścieżka bez rozszerzenia.
    static func importAudio(from source: URL, to destinationBase: URL) async throws -> (url: URL, duration: Double) {
        let fileManager = FileManager.default
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }

        let ext = source.pathExtension.lowercased()
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "m4a" : ext)
        try fileManager.copyItem(at: source, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }

        if directExtensions.contains(ext), let duration = readableDuration(of: temporary) {
            let destination = destinationBase.appendingPathExtension(ext)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: temporary, to: destination)
            return (destination, duration)
        }

        let destination = destinationBase.appendingPathExtension("m4a")
        try? fileManager.removeItem(at: destination)
        try await exportToM4A(source: temporary, destination: destination)
        guard let duration = readableDuration(of: destination) else {
            try? fileManager.removeItem(at: destination)
            throw AudioImportError.unsupported
        }
        return (destination, duration)
    }

    /// Kompresuje surowe nagranie (.caf) do .m4a. Zwraca nowy plik i długość;
    /// oryginał usuwa dopiero po udanej kompresji.
    static func compressRecording(_ source: URL, to destinationBase: URL) async throws -> (url: URL, duration: Double) {
        let destination = destinationBase.appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: destination)
        try await exportToM4A(source: source, destination: destination)
        guard let duration = readableDuration(of: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw AudioImportError.unsupported
        }
        try? FileManager.default.removeItem(at: source)
        return (destination, duration)
    }

    /// Wolne miejsce na dysku w bajtach (nil, jeśli nie da się sprawdzić).
    static func availableDiskSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Długość pliku w sekundach albo nil, jeśli nie da się go odczytać.
    static func readableDuration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    private static func exportToM4A(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioImportError.unsupported
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        guard session.status == .completed else {
            throw AudioImportError.exportFailed(session.error?.localizedDescription)
        }
    }
}
