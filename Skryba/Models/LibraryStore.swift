import Foundation
import Observation

/// Biblioteka nagrań. Każde nagranie to plik audio + plik JSON z metadanymi
/// w Application Support/Recordings.
@MainActor
@Observable
final class LibraryStore {
    private(set) var recordings: [Recording] = []
    let directory: URL

    init() {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let folder = base.appendingPathComponent("Recordings", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        recordings = LibraryStore.loadAll(from: folder)
    }

    func recording(id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func audioURL(for recording: Recording) -> URL {
        directory.appendingPathComponent(recording.audioFileName)
    }

    func insert(_ recording: Recording) {
        recordings.append(recording)
        recordings.sort { $0.createdAt > $1.createdAt }
        persist(recording)
    }

    func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var copy = recordings[index]
        change(&copy)
        guard copy != recordings[index] else { return }
        recordings[index] = copy
        persist(copy)
    }

    func delete(_ id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let recording = recordings.remove(at: index)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: audioURL(for: recording))
        try? fileManager.removeItem(at: metadataURL(for: id))
    }

    func totalSizeInBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Pliki

    private func metadataURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ recording: Recording) {
        do {
            let data = try JSONEncoder().encode(recording)
            try data.write(to: metadataURL(for: recording.id), options: .atomic)
        } catch {
            print("Skryba: nie udało się zapisać nagrania – \(error)")
        }
    }

    private static func loadAll(from directory: URL) -> [Recording] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var result: [Recording] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let recording = try? decoder.decode(Recording.self, from: data) else { continue }
            result.append(recording)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }
}
