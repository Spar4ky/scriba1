import AVFoundation
import Foundation
import Speech

/// Klasyczne rozpoznawanie mowy Apple (SFSpeechRecognizer). Dla języka polskiego
/// działa przez serwery Apple, które przyjmują maks. ~1 minutę dźwięku naraz –
/// dlatego nagranie jest dzielone na fragmenty w miejscach ciszy.
enum LegacyAppleEngine {
    static func canHandle(language: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language)) != nil
    }

    static func transcribe(
        job: TranscriptionJob,
        events: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> [TranscriptSegment] {
        try await SpeechAuthorization.ensureAuthorized()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: job.language)) else {
            throw SkrybaError.languageNotSupported(Languages.name(for: job.language))
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        if !onDevice && !recognizer.isAvailable {
            throw SkrybaError.appleServiceUnavailable
        }
        events(.engine(onDevice ? "Apple · dyktowanie na \(DeviceNames.locative)" : "Apple · serwery Apple"))
        events(.stage(nil))

        let reader = try PCMReader(url: job.audioURL)
        let chunker = SilenceChunker(reader: reader, startAt: job.resumeFrom, minDuration: 35, maxDuration: 55)
        let total = max(reader.duration, 1)
        var segments = job.partialSegments
        events(.progress(min(1, job.resumeFrom / total)))
        if !segments.isEmpty { events(.partial(segments)) }

        while let chunk = try chunker.next() {
            try Task.checkCancellation()
            var text = ""
            if chunk.duration >= 0.3 && AudioMath.peakLevel(of: chunk.samples) > -48 {
                text = try await recognize(
                    samples: chunk.samples,
                    recognizer: recognizer,
                    onDevice: onDevice,
                    contextualStrings: job.vocabulary
                )
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                segments.append(TranscriptSegment(start: chunk.start, end: chunk.end, text: cleaned))
            }
            events(.checkpoint(segments, chunk.end))
            events(.progress(min(1, chunk.end / total)))
        }
        return segments
    }

    // MARK: - Rozpoznawanie jednego fragmentu

    private static func recognize(
        samples: [Float],
        recognizer: SFSpeechRecognizer,
        onDevice: Bool,
        contextualStrings: [String]
    ) async throws -> String {
        var lastError: Error = SkrybaError.appleServiceUnavailable
        for attempt in 1...3 {
            do {
                return try await recognizeOnce(
                    samples: samples,
                    recognizer: recognizer,
                    onDevice: onDevice,
                    contextualStrings: contextualStrings
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isNoSpeech(error) { return "" }
                lastError = error
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
        throw lastError
    }

    private static func recognizeOnce(
        samples: [Float],
        recognizer: SFSpeechRecognizer,
        onDevice: Bool,
        contextualStrings: [String]
    ) async throws -> String {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMReader.sampleRate, channels: 1, interleaved: false) else {
            throw SkrybaError.audioUnreadable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        request.addsPunctuation = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        let piece = 16_000
        var index = 0
        while index < samples.count {
            let count = min(piece, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let destination = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            let offset = index
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination.update(from: base + offset, count: count)
                }
            }
            request.append(buffer)
            index += count
        }
        request.endAudio()

        let gate = OneShotContinuation<String>()
        let taskBox = RecognitionTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                gate.attach(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        gate.succeed(result.bestTranscription.formattedString)
                    } else if let error {
                        gate.fail(error)
                    }
                }
                taskBox.set(task)
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    if gate.fail(SkrybaError.timeout) {
                        taskBox.cancel()
                    }
                }
            }
        } onCancel: {
            if gate.fail(CancellationError()) {
                taskBox.cancel()
            }
        }
    }

    private static func isNoSpeech(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(nsError.code) {
            return true
        }
        return false
    }
}

/// Zgoda na rozpoznawanie mowy (wymagana przez SFSpeechRecognizer).
enum SpeechAuthorization {
    static func ensureAuthorized() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
            guard status == .authorized else { throw SkrybaError.speechPermissionDenied }
        default:
            throw SkrybaError.speechPermissionDenied
        }
    }
}

/// Gwarantuje, że kontynuacja zostanie wznowiona dokładnie raz
/// (wynik, błąd, przekroczenie czasu albo anulowanie – co pierwsze).
final class OneShotContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var earlyError: Error?
    private var completed = false

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if completed {
            let error = earlyError ?? CancellationError()
            lock.unlock()
            continuation.resume(throwing: error)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func succeed(_ value: Value) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return true
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let pending = continuation
        continuation = nil
        if pending == nil { earlyError = error }
        lock.unlock()
        pending?.resume(throwing: error)
        return true
    }
}

final class RecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    func set(_ newTask: SFSpeechRecognitionTask) {
        lock.lock()
        task = newTask
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { newTask.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}
