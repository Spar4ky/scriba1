import AVFoundation
import Observation
import UIKit

enum RecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        "Nie udało się uruchomić mikrofonu. Zamknij inne aplikacje, które nagrywają dźwięk, i spróbuj ponownie."
    }
}

/// Nagrywanie mikrofonu w tle – przy zablokowanym ekranie i w innych aplikacjach.
///
/// Zapis idzie do pliku .caf z nieskompresowanym dźwiękiem (16 kHz, mono). Taki plik da się
/// odczytać nawet wtedy, gdy telefon padnie albo aplikacja zostanie zamknięta w trakcie
/// nagrania – długi wykład nie przepadnie. Po zakończeniu nagranie jest kompresowane do .m4a.
/// Inne aplikacje mogą w tym czasie odtwarzać dźwięk (nagrywanie się nie zatrzymuje),
/// a po rozmowie telefonicznej nagrywanie wznawia się samo.
@MainActor
@Observable
final class Recorder {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    static let barCount = 56

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: 56)

    /// Wywoływane, gdy system zamyka aplikację w trakcie nagrywania (plik zostaje domknięty).
    @ObservationIgnored var onTerminate: ((TimeInterval) -> Void)?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var interruptedWhileRecording = false
    @ObservationIgnored private var resumeRetry: Task<Void, Never>?

    init() {
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, options: options)
            }
        }
        let termination = center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishBeforeTermination()
            }
        }
        observers = [interruption, termination]
    }

    var isActive: Bool { state != .idle }

    nonisolated static func requestPermission() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(writingTo url: URL) throws {
        guard recorder == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        )
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.isMeteringEnabled = true
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            releaseSession()
            throw RecorderError.couldNotStart
        }
        recorder = newRecorder
        elapsed = 0
        levels = Array(repeating: 0, count: Recorder.barCount)
        state = .recording
        // Transkrypcja w tle ustępuje nagrywaniu (mniej pamięci = iOS nie zamknie Skryby).
        AppActivity.shared.isRecording = true
        startTimer()
    }

    func pause() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        elapsed = recorder.currentTime
        state = .paused
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if recorder.record() {
            state = .recording
        }
    }

    func togglePause() {
        if state == .paused {
            resume()
        } else {
            pause()
        }
    }

    /// Kończy nagranie i zwraca jego długość w sekundach.
    @discardableResult
    func stop() -> TimeInterval {
        guard let recorder else { return 0 }
        let duration = max(recorder.currentTime, elapsed)
        recorder.stop()
        tearDown()
        return duration
    }

    /// Przerywa nagranie i usuwa plik.
    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        tearDown()
    }

    // MARK: - Prywatne

    private func tearDown() {
        resumeRetry?.cancel()
        resumeRetry = nil
        timer?.invalidate()
        timer = nil
        recorder = nil
        state = .idle
        interruptedWhileRecording = false
        AppActivity.shared.isRecording = false
        releaseSession()
    }

    /// Kończy sesję nagrywania. Jeśli trwa transkrypcja, sesja zostaje aktywna
    /// (cicha sesja w tle), żeby iOS nie uśpił Skryby.
    private func releaseSession() {
        if BackgroundKeeper.shared.isNeeded {
            BackgroundKeeper.shared.ensurePlaying()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        guard let recorder, state == .recording else { return }
        elapsed = recorder.currentTime
        // W tle (ekran zablokowany) nie liczymy wykresu – oszczędzamy baterię.
        guard UIApplication.shared.applicationState == .active else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = CGFloat(max(0, min(1, (power + 50) / 50)))
        var newLevels = levels
        if !newLevels.isEmpty { newLevels.removeFirst() }
        newLevels.append(normalized)
        levels = newLevels
    }

    private func handleInterruption(type: UInt?, options: UInt?) {
        guard recorder != nil, let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            if state == .recording {
                interruptedWhileRecording = true
                elapsed = recorder?.currentTime ?? elapsed
                state = .paused
                if UIApplication.shared.applicationState != .active {
                    Notifier.post(
                        title: "Nagrywanie wstrzymane",
                        body: "Coś przerwało nagrywanie (np. połączenie). Skryba spróbuje wznowić je sama."
                    )
                }
            }
        case .ended:
            // Wykład trwa dalej – wznawiamy zawsze, nawet gdy iOS nie da sygnału „shouldResume”.
            if interruptedWhileRecording {
                interruptedWhileRecording = false
                resumeAfterInterruption(attempt: 1)
            }
        @unknown default:
            break
        }
    }

    private func resumeAfterInterruption(attempt: Int) {
        guard state == .paused else { return }
        resume()
        if state == .recording { return }
        guard attempt < 5 else {
            Notifier.post(
                title: "Nagrywanie jest wstrzymane",
                body: "Otwórz Skrybę i dotknij ▶︎, żeby nagrywać dalej."
            )
            return
        }
        resumeRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.resumeAfterInterruption(attempt: attempt + 1)
        }
    }

    private func finishBeforeTermination() {
        guard recorder != nil else { return }
        let duration = stop()
        onTerminate?(duration)
    }
}
