import AVFoundation
import Foundation

/// Utrzymuje Skrybę przy życiu w tle, gdy czeka ją transkrypcja.
///
/// iOS usypia aplikację ok. 30 s po wyjściu z niej. Aplikacje z trybem „audio” mogą
/// działać dalej, dopóki ich sesja dźwiękowa gra – dlatego na czas transkrypcji Skryba
/// odtwarza ciszę. Sesja miesza się z innymi aplikacjami (muzyka, filmy grają normalnie)
/// i nie przejmuje ekranu blokady. Nagrywanie ma pierwszeństwo – jego ustawień nie ruszamy.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private(set) var isNeeded = false
    /// Użytkownik słucha nagrania na ekranie szczegółów (wtedy nie zmieniamy kategorii sesji).
    var userPlaybackActive = false

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let type, AVAudioSession.InterruptionType(rawValue: type) == .ended else { return }
                self?.ensurePlaying()
            }
        }
        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player = nil
                self?.ensurePlaying()
            }
        }
        observers = [interruption, reset]
    }

    func setNeeded(_ needed: Bool) {
        guard needed != isNeeded else {
            if needed {
                ensurePlaying()
            }
            return
        }
        isNeeded = needed
        if needed {
            ensurePlaying()
            DiagnosticsLog.add("Praca w tle włączona (cicha sesja audio)")
        } else {
            player?.stop()
            player = nil
            if !AppActivity.shared.isRecording && !userPlaybackActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// Włącza (albo przywraca, np. po rozmowie telefonicznej) cichą sesję.
    func ensurePlaying() {
        guard isNeeded else { return }
        let session = AVAudioSession.sharedInstance()
        if !AppActivity.shared.isRecording && !userPlaybackActive {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
        if player == nil {
            player = BackgroundKeeper.makeSilentPlayer()
        }
        if let player, !player.isPlaying {
            player.play()
        }
    }

    private static func makeSilentPlayer() -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: SilentAudio.wav(seconds: 2)) else {
            DiagnosticsLog.add("Nie udało się przygotować cichej sesji audio")
            return nil
        }
        player.numberOfLoops = -1
        player.prepareToPlay()
        return player
    }
}

/// Generuje plik WAV z ciszą (16 bitów, mono, 8 kHz).
enum SilentAudio {
    static func wav(seconds: Double) -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount = UInt32(Double(sampleRate) * seconds)
        let dataSize = sampleCount * 2
        var data = Data()

        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
