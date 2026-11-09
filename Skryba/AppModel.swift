import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let icon: String
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var offersSettings = false
}

/// Stan całej aplikacji: biblioteka, nagrywanie, import, kolejka transkrypcji.
@MainActor
@Observable
final class AppModel {
    let store: LibraryStore
    let transcriber: TranscriptionManager
    let recorder: Recorder

    var path: [UUID] = []
    var isRecorderPresented = false
    var isSettingsPresented = false
    var isImporterPresented = false
    var isImporting = false
    var busyMessage = "Dodaję nagranie…"
    var toast: Toast?
    var alert: AppAlert?
    /// Postęp ręcznego pobierania modelu Whisper (nil = nic się nie pobiera).
    var modelDownloadProgress: Double?
    /// Zwiększane po pobraniu/usunięciu modelu, żeby widoki odświeżyły stan.
    var modelRevision = 0

    var isAlertPresented: Bool {
        get { alert != nil }
        set { if !newValue { alert = nil } }
    }

    @ObservationIgnored private var activeRecordingID: UUID?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var isImportingInbox = false
    @ObservationIgnored private var isActive = true

    init() {
        let library = LibraryStore()
        store = library
        transcriber = TranscriptionManager(store: library)
        recorder = Recorder()
        transcriber.onFinished = { [weak self] recording in
            self?.transcriptionFinished(recording)
        }
        recorder.onTerminate = { [weak self] duration in
            self?.persistInterruptedRecording(duration: duration)
        }
        recoverInterruptedRecordings()
    }

    // MARK: - Nagrywanie

    func beginRecording() async {
        if recorder.isActive {
            isRecorderPresented = true
            return
        }
        let granted = await Recorder.requestPermission()
        guard granted else {
            alert = AppAlert(
                title: "Brak dostępu do mikrofonu",
                message: "Włącz mikrofon dla Skryby w Ustawieniach iPhone’a, żeby nagrywać wykłady.",
                offersSettings: true
            )
            return
        }
        isRecorderPresented = true
    }

    func startRecording() {
        guard !recorder.isActive else { return }
        // 1,5 h nieskompresowanego nagrania to ok. 175 MB – sprawdzamy wolne miejsce.
        if let free = AudioImporter.availableDiskSpace(at: store.directory), free < 400_000_000 {
            isRecorderPresented = false
            alert = AppAlert(
                title: "Za mało miejsca",
                message: "Na iPhonie zostało mniej niż 400 MB. Długi wykład może się nie zmieścić – zwolnij miejsce i spróbuj ponownie."
            )
            return
        }
        let id = UUID()
        let url = store.directory.appendingPathComponent("\(id.uuidString).caf")
        do {
            try recorder.start(writingTo: url)
        } catch {
            isRecorderPresented = false
            presentError(error.localizedDescription)
            return
        }
        let recording = Recording(
            id: id,
            title: AppModel.defaultTitle(),
            duration: 0,
            audioFileName: url.lastPathComponent,
            source: .microphone,
            language: SettingsSnapshot.current().language,
            status: .recording
        )
        store.insert(recording)
        activeRecordingID = id
    }

    func stopRecording(title: String) {
        let duration = recorder.stop()
        isRecorderPresented = false
        guard let id = activeRecordingID else { return }
        activeRecordingID = nil
        if duration < 1 {
            store.delete(id)
            showToast("Nagranie było za krótkie", icon: "exclamationmark.circle.fill")
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = SettingsSnapshot.current().language
        store.update(id) { recording in
            recording.duration = duration
            recording.language = language
            if !trimmed.isEmpty {
                recording.title = trimmed
            }
        }
        Task { [weak self] in
            await self?.compressAndTranscribe(id)
        }
    }

    /// Kompresuje surowe nagranie do .m4a (zajmuje ok. 10× mniej miejsca), potem rusza transkrypcja.
    private func compressAndTranscribe(_ id: UUID) async {
        guard let recording = store.recording(id: id) else { return }
        let source = store.audioURL(for: recording)
        if source.pathExtension.lowercased() == "caf" {
            busyMessage = "Zapisuję nagranie…"
            isImporting = true
            let base = store.directory.appendingPathComponent(id.uuidString)
            if let compressed = try? await AudioImporter.compressRecording(source, to: base) {
                store.update(id) { item in
                    item.audioFileName = compressed.url.lastPathComponent
                    item.duration = compressed.duration
                }
            }
            isImporting = false
            busyMessage = "Dodaję nagranie…"
        }
        store.update(id) { $0.status = .pending }
        transcriber.enqueue(id)
        open(id, afterDelay: true)
    }

    func discardRecording() {
        recorder.cancel()
        if let id = activeRecordingID {
            store.delete(id)
        }
        activeRecordingID = nil
        isRecorderPresented = false
    }

    private func persistInterruptedRecording(duration: TimeInterval) {
        guard let id = activeRecordingID else { return }
        activeRecordingID = nil
        store.update(id) { recording in
            recording.duration = duration
            recording.status = .pending
        }
    }

    private func recoverInterruptedRecordings() {
        for recording in store.recordings where recording.status == .recording {
            let url = store.audioURL(for: recording)
            if let duration = AudioImporter.readableDuration(of: url), duration >= 1 {
                // Nagranie przerwane (np. padła bateria) – odzyskujemy je i kompresujemy.
                store.update(recording.id) { item in
                    item.duration = duration
                    item.title = item.title + " (odzyskane)"
                }
                Task { [weak self] in
                    await self?.compressAndTranscribe(recording.id)
                }
            } else {
                store.update(recording.id) { item in
                    item.status = .failed
                    item.errorMessage = "Nagrywanie zostało przerwane, a plik dźwiękowy jest niekompletny."
                }
            }
        }
    }

    // MARK: - Cykl życia

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            transcriber.appDidBecomeActive()
            importFromShareExtension()
        case .background:
            isActive = false
            transcriber.appDidEnterBackground()
        default:
            break
        }
    }

    // MARK: - Import (Pliki, „Otwórz w…”, rozszerzenie „Transkrybuj”)

    func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            Task { await importFiles([url], source: .shared) }
        } else {
            importFromShareExtension()
        }
    }

    func importFiles(_ urls: [URL], source: Recording.Source) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        var lastImported: UUID?
        for url in urls {
            do {
                lastImported = try await importAudio(at: url, title: nil, source: source)
            } catch {
                presentError("Nie udało się dodać pliku „\(url.lastPathComponent)”. \(error.localizedDescription)")
            }
            if url.path.contains("/Documents/Inbox/") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        isImporting = false
        if let lastImported {
            open(lastImported, afterDelay: false)
        }
    }

    func importFromShareExtension() {
        guard !isImportingInbox else { return }
        let items = Inbox.pendingItems()
        guard !items.isEmpty else { return }
        isImportingInbox = true
        isImporting = true
        Task { [weak self] in
            guard let self else { return }
            var lastImported: UUID?
            for item in items {
                do {
                    lastImported = try await self.importAudio(at: item.audioURL, title: item.manifest.title, source: .shared)
                } catch {
                    self.presentError("Nie udało się dodać nagrania z Dyktafonu. \(error.localizedDescription)")
                }
                Inbox.remove(item)
            }
            self.isImporting = false
            self.isImportingInbox = false
            if let lastImported {
                self.open(lastImported, afterDelay: false)
            }
        }
    }

    private func importAudio(at url: URL, title: String?, source: Recording.Source) async throws -> UUID {
        let id = UUID()
        let base = store.directory.appendingPathComponent(id.uuidString)
        let imported = try await AudioImporter.importAudio(from: url, to: base)
        let recording = Recording(
            id: id,
            title: title ?? AppModel.title(for: url),
            duration: imported.duration,
            audioFileName: imported.url.lastPathComponent,
            source: source,
            language: SettingsSnapshot.current().language,
            status: .pending
        )
        store.insert(recording)
        transcriber.enqueue(id)
        return id
    }

    private func open(_ id: UUID, afterDelay: Bool) {
        if recorder.isActive {
            showToast("Dodano nagranie – czeka w bibliotece", icon: "tray.and.arrow.down.fill")
            return
        }
        Task { [weak self] in
            if afterDelay {
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
            self?.isSettingsPresented = false
            self?.path = [id]
        }
    }

    // MARK: - Akcje na nagraniach

    func copyTranscript(_ recording: Recording) {
        let text = TranscriptFormatter.plainText(for: recording, timestamps: SettingsSnapshot.current().copyTimestamps)
        guard !text.isEmpty else {
            showToast("Brak tekstu do skopiowania", icon: "exclamationmark.circle.fill")
            return
        }
        UIPasteboard.general.string = text
        showToast("Skopiowano · \(Plural.words(TranscriptFormatter.wordCount(text)))", icon: "checkmark.circle.fill")
    }

    func delete(_ id: UUID) {
        if transcriber.isQueuedOrActive(id) {
            transcriber.cancel(id)
        }
        path.removeAll { $0 == id }
        store.delete(id)
        showToast("Usunięto nagranie", icon: "trash.fill")
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update(id) { $0.title = trimmed }
    }

    /// Ponawia transkrypcję od miejsca przerwania.
    func retry(_ id: UUID) {
        transcriber.enqueue(id)
    }

    /// Robi transkrypcję od nowa (opcjonalnie w innym języku).
    func retranscribe(_ id: UUID, language: String?) {
        if let language {
            store.update(id) { $0.language = language }
        }
        transcriber.enqueue(id, restart: true)
    }

    func cancelTranscription(_ id: UUID) {
        transcriber.cancel(id)
    }

    func saveEditedText(_ id: UUID, text: String?) {
        store.update(id) { recording in
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let original = TranscriptFormatter.plainText(segments: recording.segments, timestamps: false)
            if trimmed.isEmpty || trimmed == original.trimmingCharacters(in: .whitespacesAndNewlines) {
                recording.editedText = nil
            } else {
                recording.editedText = text
            }
        }
    }

    // MARK: - Model Whisper

    func downloadModel(_ variant: String) {
        guard modelDownloadProgress == nil else { return }
        modelDownloadProgress = 0
        Task { [weak self] in
            do {
                _ = try await WhisperModelHost.ensureDownloaded(variant: variant) { fraction in
                    Task { @MainActor in
                        guard let self, self.modelDownloadProgress != nil else { return }
                        self.modelDownloadProgress = fraction
                    }
                }
                self?.modelDownloadProgress = nil
                self?.modelRevision += 1
                self?.showToast("Model Whisper pobrany", icon: "checkmark.circle.fill")
            } catch {
                self?.modelDownloadProgress = nil
                self?.presentError(SkrybaError.describe(error))
            }
        }
    }

    func deleteModel(_ variant: String) {
        Task {
            await WhisperModelHost.shared.unload()
            WhisperModelHost.delete(variant)
            modelRevision += 1
            showToast("Usunięto model", icon: "trash.fill")
        }
    }

    // MARK: - Komunikaty

    func showToast(_ message: String, icon: String) {
        toast = Toast(message: message, icon: icon)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func presentError(_ message: String) {
        alert = AppAlert(title: "Coś poszło nie tak", message: message)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func transcriptionFinished(_ recording: Recording) {
        let settings = SettingsSnapshot.current()
        if isActive {
            if !recording.hasTranscript {
                showToast("Nie wykryto mowy w nagraniu", icon: "waveform")
            } else if settings.autoCopy {
                copyTranscript(recording)
            } else {
                showToast("Transkrypcja gotowa", icon: "checkmark.circle.fill")
            }
        } else {
            Notifier.post(
                title: "Transkrypcja gotowa",
                body: "„\(recording.title)” – otwórz Skrybę, żeby skopiować tekst."
            )
        }
    }

    // MARK: - Pomocnicze

    static func defaultTitle() -> String {
        "Nagranie " + Date().formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || UUID(uuidString: name) != nil {
            return defaultTitle()
        }
        return name
    }
}
