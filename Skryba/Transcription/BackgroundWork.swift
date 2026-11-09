import Foundation

/// Stan aplikacji czytelny z każdego wątku: czy Skryba jest w tle i czy nagrywa.
/// Silnik transkrypcji na tej podstawie decyduje, czy i jak może pracować.
final class AppActivity: @unchecked Sendable {
    static let shared = AppActivity()

    private let lock = NSLock()
    private var background = false
    private var recording = false

    var isInBackground: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return background
        }
        set {
            lock.lock()
            background = newValue
            lock.unlock()
        }
    }

    var isRecording: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return recording
        }
        set {
            lock.lock()
            recording = newValue
            lock.unlock()
        }
    }
}

/// Pauza transkrypcji (to nie błąd): gdy Skryba nagrywa w tle, nagrywanie ma pierwszeństwo.
/// Model zostaje zwolniony z pamięci, żeby iOS nie zamknął aplikacji w trakcie wykładu.
enum TranscriptionPause: Error {
    case recordingInBackground
}

/// Czy Skryba może przepisywać nagrania, gdy jest w tle?
///
/// iOS/iPadOS 26 na to pozwala (bez karty graficznej). iOS/iPadOS 27 ogranicza dostęp
/// do Neural Engine w tle, a każdy system zamyka aplikacje, które w tle zużywają za dużo
/// procesora. Zapamiętujemy, jak to wyszło w praktyce na tym urządzeniu i tej wersji systemu:
/// jeśli praca w tle się nie udaje, transkrypcja czeka na powrót do Skryby.
enum BackgroundWorkGuard {
    /// Fragment w trakcie przetwarzania (gdy zostanie po zamknięciu aplikacji – coś ją przerwało).
    private static let runningKey = "skryba.bgWork.running"
    /// Skryba była w tle z pracą do wykonania.
    private static let inBackgroundKey = "skryba.bgWork.inBackground"

    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var failuresKey: String { "skryba.bgWork.failures.\(systemVersion)" }
    private static var successKey: String { "skryba.bgWork.success.\(systemVersion)" }

    /// Od wersji 27 Apple ogranicza Neural Engine w tle – tolerujemy tylko jedną porażkę.
    static let isRestrictiveSystem = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    )

    static var isAllowed: Bool {
        UserDefaults.standard.integer(forKey: failuresKey) < (isRestrictiveSystem ? 1 : 2)
    }

    static var hasWorkedInBackground: Bool {
        UserDefaults.standard.bool(forKey: successKey)
    }

    /// Przy starcie: czy system zamknął Skrybę w trakcie pracy w tle (np. za duże zużycie procesora)?
    static func checkPreviousRun() {
        let defaults = UserDefaults.standard
        let wasWorking = defaults.bool(forKey: runningKey)
        let wasInBackground = defaults.bool(forKey: inBackgroundKey)
        defaults.removeObject(forKey: runningKey)
        defaults.removeObject(forKey: inBackgroundKey)
        if wasWorking && wasInBackground {
            recordFailure("System zamknął Skrybę podczas transkrypcji w tle")
        }
    }

    static func appEnteredBackground() {
        UserDefaults.standard.set(true, forKey: inBackgroundKey)
    }

    static func appBecameActive() {
        UserDefaults.standard.removeObject(forKey: inBackgroundKey)
    }

    static func chunkStarted() {
        UserDefaults.standard.set(true, forKey: runningKey)
    }

    /// `ranInBackground` – fragment w całości przeszedł w tle (dowód, że praca w tle działa).
    static func chunkFinished(succeeded: Bool, ranInBackground: Bool) {
        UserDefaults.standard.removeObject(forKey: runningKey)
        if succeeded && ranInBackground && !hasWorkedInBackground {
            UserDefaults.standard.set(true, forKey: successKey)
            DiagnosticsLog.add("Transkrypcja w tle działa na tym urządzeniu")
        }
    }

    static func recordFailure(_ reason: String, definite: Bool = false) {
        let current = UserDefaults.standard.integer(forKey: failuresKey)
        let updated = definite ? max(current + 1, 2) : current + 1
        UserDefaults.standard.set(updated, forKey: failuresKey)
        let outcome = isAllowed ? "spróbujemy jeszcze raz" : "odtąd w tle transkrypcja czeka na powrót do Skryby"
        DiagnosticsLog.add("\(reason) – \(outcome)")
    }

    /// Ponowne sprawdzenie (np. po aktualizacji systemu albo z Ustawień).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: failuresKey)
        UserDefaults.standard.removeObject(forKey: successKey)
        UserDefaults.standard.removeObject(forKey: runningKey)
        DiagnosticsLog.add("Praca w tle: ponowne sprawdzenie")
    }

    static var statusDescription: String {
        if !isAllowed {
            return "czeka na powrót (system nie pozwala)"
        }
        return hasWorkedInBackground ? "działa" : "jeszcze nie sprawdzona"
    }
}

/// Bramka przed każdym fragmentem nagrania: w tle Skryba albo pracuje oszczędnie,
/// albo czeka, aż do niej wrócisz – bez zaczynania od nowa.
enum BackgroundGate {
    /// W tle fragmenty są krótsze (ok. 30 s), żeby rozłożyć obciążenie procesora.
    static let backgroundChunkLimit: Double = 30

    /// Rzuca `TranscriptionPause`, gdy w tle trwa nagrywanie; czeka, gdy system nie pozwala pracować w tle.
    static func checkpoint(events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        let activity = AppActivity.shared
        guard activity.isInBackground else { return }
        if activity.isRecording {
            throw TranscriptionPause.recordingInBackground
        }
        if !BackgroundWorkGuard.isAllowed {
            events(.waitingForForeground(true))
            await waitForForeground()
            events(.waitingForForeground(false))
        }
    }

    static func waitForForeground() async {
        while AppActivity.shared.isInBackground && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// iOS zamyka aplikacje, które w tle zużywają ponad 80% procesora przez minutę.
    /// Po każdym fragmencie w tle robimy przerwę, żeby średnio zostać przy ok. 50%.
    static func throttle(cpuUsed: TimeInterval, wall: TimeInterval) async {
        guard AppActivity.shared.isInBackground, cpuUsed > 0 else { return }
        let pause = cpuUsed / 0.5 - wall
        guard pause > 0.2 else { return }
        try? await Task.sleep(nanoseconds: UInt64(min(pause, 120) * 1_000_000_000))
    }
}

enum ProcessCPU {
    /// Czas procesora zużyty przez całą aplikację (wszystkie wątki), w sekundach.
    static func seconds() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
