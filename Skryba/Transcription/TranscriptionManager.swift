import Foundation
import Observation
import UIKit

/// Kolejka transkrypcji: przetwarza nagrania po kolei, raportuje postęp,
/// zapisuje punkty kontrolne i wznawia pracę po powrocie do aplikacji.
@MainActor
@Observable
final class TranscriptionManager {
    struct LiveState: Equatable {
        var progress: Double = 0
        var stage: String?
        var engine: String?
        var preview: [TranscriptSegment] = []
    }

    private(set) var live: [UUID: LiveState] = [:]
    private(set) var activeID: UUID?

    /// Wywoływane po udanej transkrypcji.
    @ObservationIgnored var onFinished: ((Recording) -> Void)?

    private let store: LibraryStore
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeKey: String?
    @ObservationIgnored private var interruptedByBackground = false
    @ObservationIgnored private var cancelledByUser = false
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - Kolejka

    /// Dodaje nagranie do kolejki. `restart` kasuje wyniki częściowe (np. zmiana języka).
    func enqueue(_ id: UUID, restart: Bool = false) {
        guard activeID != id else { return }
        store.update(id) { recording in
            recording.status = .pending
            recording.errorMessage = nil
            if restart {
                recording.checkpoint = 0
                recording.checkpointKey = nil
                recording.partialSegments = []
            }
        }
        if !queue.contains(id) {
            queue.append(id)
        }
        Notifier.requestAuthorizationIfNeeded()
        startNextIfPossible()
    }

    /// Wznawia wszystko, co czeka (np. po ponownym uruchomieniu aplikacji).
    func resumePending() {
        let candidates = store.recordings
            .filter { $0.id != activeID && ($0.status == .pending || $0.status == .transcribing) }
            .sorted { $0.createdAt < $1.createdAt }
        for recording in candidates {
            if recording.status == .transcribing {
                store.update(recording.id) { $0.status = .pending }
            }
            if !queue.contains(recording.id) {
                queue.append(recording.id)
            }
        }
        startNextIfPossible()
    }

    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if activeID == id {
            cancelledByUser = true
            worker?.cancel()
        } else {
            store.update(id) { recording in
                if recording.status == .pending {
                    recording.status = .failed
                    recording.errorMessage = "Transkrypcja anulowana."
                }
            }
        }
    }

    func isQueuedOrActive(_ id: UUID) -> Bool {
        activeID == id || queue.contains(id)
    }

    // MARK: - Cykl życia aplikacji

    func appDidBecomeActive() {
        isAppActive = true
        endBackgroundTask()
        resumePending()
    }

    func appDidEnterBackground() {
        isAppActive = false
        guard activeID != nil else { return }
        interruptedByBackground = true
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transkrypcja") { [weak self] in
                MainActor.assumeIsolated {
                    self?.endBackgroundTask()
                }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Praca

    private func startNextIfPossible() {
        guard activeID == nil, isAppActive else { return }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let recording = store.recording(id: id), recording.status == .pending else { continue }
            start(recording)
            return
        }
    }

    private func start(_ recording: Recording) {
        let job = makeJob(for: recording, settings: SettingsSnapshot.current())
        let id = recording.id
        activeID = id
        activeKey = job.checkpointKey
        interruptedByBackground = false
        cancelledByUser = false
        let initialProgress = recording.duration > 0 ? min(1, job.resumeFrom / recording.duration) : 0
        live[id] = LiveState(progress: initialProgress, stage: "Przygotowanie…", engine: nil, preview: job.partialSegments)
        store.update(id) { recording in
            recording.status = .transcribing
            recording.errorMessage = nil
        }
        UIApplication.shared.isIdleTimerDisabled = true

        let sink: @Sendable (TranscriptionEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                self?.handle(event, for: id)
            }
        }
        worker = Task { [weak self] in
            let operation = Task.detached(priority: .userInitiated) {
                try await TranscriptionService.run(job, events: sink)
            }
            let result = await withTaskCancellationHandler {
                await operation.result
            } onCancel: {
                operation.cancel()
            }
            self?.finish(id: id, result: result)
        }
    }

    private func handle(_ event: TranscriptionEvent, for id: UUID) {
        guard activeID == id, var state = live[id] else { return }
        switch event {
        case .engine(let label):
            state.engine = label
            store.update(id) { $0.engineLabel = label }
        case .stage(let text):
            state.stage = text
        case .progress(let value):
            state.progress = min(max(value, 0), 1)
        case .partial(let segments):
            state.preview = segments
        case .checkpoint(let segments, let until):
            state.preview = segments
            let key = activeKey
            if let current = store.recording(id: id), until > current.checkpoint {
                store.update(id) { recording in
                    recording.partialSegments = segments
                    recording.checkpoint = until
                    recording.checkpointKey = key
                }
            }
        }
        live[id] = state
    }

    private func finish(id: UUID, result: Result<[TranscriptSegment], Error>) {
        activeID = nil
        activeKey = nil
        worker = nil
        live[id] = nil
        UIApplication.shared.isIdleTimerDisabled = false
        let wasInterrupted = interruptedByBackground
        let wasCancelled = cancelledByUser
        interruptedByBackground = false
        cancelledByUser = false

        switch result {
        case .success(let segments):
            store.update(id) { recording in
                recording.segments = segments
                recording.editedText = nil
                recording.status = .done
                recording.transcribedAt = Date()
                recording.partialSegments = []
                recording.checkpoint = 0
                recording.checkpointKey = nil
                recording.errorMessage = nil
            }
            if let recording = store.recording(id: id) {
                onFinished?(recording)
            }
        case .failure(let error):
            if wasCancelled || error is CancellationError {
                store.update(id) { recording in
                    recording.status = .failed
                    recording.errorMessage = "Transkrypcja anulowana. Dotknij „Spróbuj ponownie”, aby wznowić."
                }
            } else if wasInterrupted || !isAppActive {
                store.update(id) { $0.status = .pending }
                if !queue.contains(id) {
                    queue.insert(id, at: 0)
                }
            } else {
                let message = SkrybaError.describe(error)
                store.update(id) { recording in
                    recording.status = .failed
                    recording.errorMessage = message
                }
            }
        }
        if !isAppActive {
            endBackgroundTask()
        }
        startNextIfPossible()
    }

    private func makeJob(for recording: Recording, settings: SettingsSnapshot) -> TranscriptionJob {
        let engine = settings.engine
        let model = settings.model(for: engine)
        let key = [engine.rawValue, recording.language, model].joined(separator: "|")
        let canResume = recording.checkpointKey == key && recording.checkpoint > 0
        return TranscriptionJob(
            recordingID: recording.id,
            audioURL: store.audioURL(for: recording),
            language: recording.language,
            engine: engine,
            model: model,
            farField: settings.farField,
            vocabulary: settings.vocabularyList,
            resumeFrom: canResume ? recording.checkpoint : 0,
            partialSegments: canResume ? recording.partialSegments : [],
            checkpointKey: key
        )
    }
}
