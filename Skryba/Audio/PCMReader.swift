import Accelerate
import AVFoundation

enum PCMError: LocalizedError {
    case unreadable
    case conversion

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Nie udało się odczytać pliku dźwiękowego."
        case .conversion: return "Nie udało się przetworzyć dźwięku."
        }
    }
}

/// Fragment nagrania: próbki 16 kHz mono + początek w sekundach.
struct PCMChunk {
    let start: Double
    let samples: [Float]

    var duration: Double { Double(samples.count) / PCMReader.sampleRate }
    var end: Double { start + duration }
}

/// Czyta dowolny plik audio i oddaje próbki 16 kHz mono (Float32) blokami ~1 s.
final class PCMReader {
    static let sampleRate: Double = 16_000

    let duration: Double
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let blockFrames: AVAudioFrameCount
    private var finished = false

    init(url: URL) throws {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw PCMError.unreadable
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMReader.sampleRate, channels: 1, interleaved: false),
              let audioConverter = AVAudioConverter(from: audioFile.processingFormat, to: format) else {
            throw PCMError.conversion
        }
        audioConverter.downmix = true
        let inputRate = audioFile.processingFormat.sampleRate
        file = audioFile
        converter = audioConverter
        outputFormat = format
        blockFrames = AVAudioFrameCount(max(inputRate, 8_000))
        duration = inputRate > 0 ? Double(audioFile.length) / inputRate : 0
    }

    func seek(to seconds: Double) {
        let rate = file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(max(0, seconds) * rate)
        file.framePosition = min(frame, file.length)
        converter.reset()
        finished = false
    }

    /// Następny blok próbek albo nil na końcu pliku.
    func nextBlock() throws -> [Float]? {
        if finished { return nil }
        if file.framePosition >= file.length {
            finished = true
            let tail = try convert(nil)
            return tail.isEmpty ? nil : tail
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames) else {
            throw PCMError.conversion
        }
        try file.read(into: input, frameCount: blockFrames)
        if input.frameLength == 0 {
            finished = true
            let tail = try convert(nil)
            return tail.isEmpty ? nil : tail
        }
        return try convert(input)
    }

    private func convert(_ input: AVAudioPCMBuffer?) throws -> [Float] {
        let ratio = outputFormat.sampleRate / file.processingFormat.sampleRate
        let inputFrames = Double(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw PCMError.conversion
        }
        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let input else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            if let conversionError { throw conversionError }
            throw PCMError.conversion
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Dzieli nagranie na fragmenty, tnąc w najcichszym miejscu (żeby nie przecinać słów).
final class SilenceChunker {
    private let reader: PCMReader
    private let minSamples: Int
    private let maxSamples: Int
    private var pending: [Float] = []
    private var pendingStart: Double
    private var exhausted = false

    init(reader: PCMReader, startAt: Double, minDuration: Double, maxDuration: Double) {
        self.reader = reader
        self.minSamples = Int(minDuration * PCMReader.sampleRate)
        self.maxSamples = Int(maxDuration * PCMReader.sampleRate)
        self.pendingStart = max(0, startAt)
        reader.seek(to: max(0, startAt))
    }

    func next() throws -> PCMChunk? {
        while !exhausted && pending.count < maxSamples {
            if let block = try reader.nextBlock() {
                pending.append(contentsOf: block)
            } else {
                exhausted = true
            }
        }
        guard !pending.isEmpty else { return nil }
        let cut: Int
        if exhausted && pending.count <= maxSamples {
            cut = pending.count
        } else {
            cut = AudioMath.quietestPoint(in: pending, from: minSamples, to: min(maxSamples, pending.count))
        }
        let samples = Array(pending[0..<cut])
        pending.removeFirst(cut)
        let chunk = PCMChunk(start: pendingStart, samples: samples)
        pendingStart += Double(cut) / PCMReader.sampleRate
        return chunk
    }
}

enum AudioMath {
    /// Środek najcichszego okna 250 ms w zakresie [lower, upper).
    static func quietestPoint(in samples: [Float], from lower: Int, to upper: Int) -> Int {
        let rate = Int(PCMReader.sampleRate)
        let window = rate / 4
        let step = rate / 20
        let low = max(0, min(lower, samples.count))
        let high = max(low, min(upper, samples.count))
        guard high - low > window else { return max(1, high) }
        var bestEnergy = Float.greatestFiniteMagnitude
        var bestIndex = high
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = low
            while start + window <= high {
                var energy: Float = 0
                vDSP_svesq(base + start, 1, &energy, vDSP_Length(window))
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestIndex = start + window / 2
                }
                start += step
            }
        }
        return max(1, min(bestIndex, samples.count))
    }

    /// Najgłośniejsze okno 0,5 s w dBFS – pozwala pominąć fragmenty samej ciszy.
    static func peakLevel(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160 }
        let window = Int(PCMReader.sampleRate) / 2
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                let length = min(window, buffer.count - start)
                var energy: Float = 0
                vDSP_svesq(base + start, 1, &energy, vDSP_Length(length))
                let rms = (energy / Float(length)).squareRoot()
                if rms > peak { peak = rms }
                start += length
            }
        }
        return peak > 0 ? 20 * log10(peak) : -160
    }
}
