import Foundation

/// Fragment transkrypcji z czasem w nagraniu (w sekundach).
struct TranscriptSegment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Jedno nagranie w bibliotece (metadane + transkrypcja).
struct Recording: Identifiable, Codable, Hashable {
    enum Status: String, Codable, Sendable {
        case recording
        case pending
        case transcribing
        case done
        case failed
    }

    enum Source: String, Codable, Sendable {
        case microphone
        case imported
        case shared
    }

    var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    var audioFileName: String
    var source: Source
    var language: String
    var status: Status
    var engineLabel: String?
    var segments: [TranscriptSegment]
    var editedText: String?
    var errorMessage: String?
    /// Wyniki częściowe (pozwalają wznowić przerwaną transkrypcję).
    var partialSegments: [TranscriptSegment]
    /// Do której sekundy nagranie zostało już przetworzone.
    var checkpoint: Double
    /// Silnik + język, którym liczone były wyniki częściowe.
    var checkpointKey: String?
    var transcribedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: Double,
        audioFileName: String,
        source: Source,
        language: String,
        status: Status
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.source = source
        self.language = language
        self.status = status
        self.engineLabel = nil
        self.segments = []
        self.editedText = nil
        self.errorMessage = nil
        self.partialSegments = []
        self.checkpoint = 0
        self.checkpointKey = nil
        self.transcribedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case duration
        case audioFileName
        case source
        case language
        case status
        case engineLabel
        case segments
        case editedText
        case errorMessage
        case partialSegments
        case checkpoint
        case checkpointKey
        case transcribedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Nagranie"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        audioFileName = try container.decode(String.self, forKey: .audioFileName)
        source = (try? container.decodeIfPresent(Source.self, forKey: .source)) ?? .microphone
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "pl-PL"
        status = (try? container.decodeIfPresent(Status.self, forKey: .status)) ?? .pending
        engineLabel = try container.decodeIfPresent(String.self, forKey: .engineLabel)
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        editedText = try container.decodeIfPresent(String.self, forKey: .editedText)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        partialSegments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .partialSegments) ?? []
        checkpoint = try container.decodeIfPresent(Double.self, forKey: .checkpoint) ?? 0
        checkpointKey = try container.decodeIfPresent(String.self, forKey: .checkpointKey)
        transcribedAt = try container.decodeIfPresent(Date.self, forKey: .transcribedAt)
    }
}

extension Recording {
    var hasTranscript: Bool {
        if let editedText, !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !segments.isEmpty
    }

    var searchableText: String {
        if let editedText { return editedText }
        return segments.map(\.text).joined(separator: " ")
    }

    var previewText: String? {
        let raw: String
        if let editedText {
            raw = editedText
        } else {
            raw = segments.prefix(6).map(\.text).joined(separator: " ")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(240))
    }
}
