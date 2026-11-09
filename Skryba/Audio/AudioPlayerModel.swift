import AVFoundation
import Observation

/// Odtwarzacz nagrania na ekranie szczegółów (z prędkością i przewijaniem).
@MainActor
@Observable
final class AudioPlayerModel {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var isReady = false
    var isScrubbing = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadedURL: URL?

    func load(url: URL) {
        if loadedURL == url, player != nil { return }
        unload()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.enableRate = true
            newPlayer.prepareToPlay()
            player = newPlayer
            loadedURL = url
            duration = newPlayer.duration
            currentTime = 0
            isReady = true
        } catch {
            isReady = false
        }
    }

    func unload() {
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        player.rate = rate
        if player.play() {
            isPlaying = true
            startTimer()
        }
    }

    func play(from time: Double) {
        seek(to: time)
        play()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        isPlaying = false
        currentTime = player.currentTime
        stopTimer()
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player?.rate = newRate
    }

    // MARK: - Prywatne

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        if !isScrubbing {
            currentTime = player.currentTime
        }
        if isPlaying && !player.isPlaying {
            isPlaying = false
            currentTime = player.currentTime
            stopTimer()
        }
    }
}
