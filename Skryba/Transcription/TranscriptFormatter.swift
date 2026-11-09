import Foundation

/// Akapit transkrypcji (do wyświetlania i kopiowania).
struct TranscriptParagraph: Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
}

enum TranscriptFormatter {
    /// Skleja fragmenty w czytelne akapity: nowy akapit po dłuższej pauzie
    /// albo gdy bieżący robi się za długi (i kończy się zdanie).
    static func paragraphs(from segments: [TranscriptSegment]) -> [TranscriptParagraph] {
        var result: [TranscriptParagraph] = []
        var texts: [String] = []
        var start: Double = 0
        var end: Double = 0
        var length = 0

        func flush() {
            guard !texts.isEmpty else { return }
            result.append(TranscriptParagraph(id: result.count, start: start, end: end, text: texts.joined(separator: " ")))
            texts.removeAll()
            length = 0
        }

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = texts.last {
                let gap = segment.start - end
                let sentenceEnded = endsSentence(last)
                if gap > 2.5 || (length > 550 && sentenceEnded) || length > 1_200 {
                    flush()
                }
            }
            if texts.isEmpty {
                start = segment.start
                end = segment.end
            } else {
                end = max(end, segment.end)
            }
            texts.append(text)
            length += text.count + 1
        }
        flush()
        return result
    }

    static func plainText(for recording: Recording, timestamps: Bool) -> String {
        if let edited = recording.editedText?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty {
            return edited
        }
        return plainText(segments: recording.segments, timestamps: timestamps)
    }

    static func plainText(segments: [TranscriptSegment], timestamps: Bool) -> String {
        paragraphs(from: segments)
            .map { paragraph in
                timestamps ? "[\(clock(paragraph.start))] \(paragraph.text)" : paragraph.text
            }
            .joined(separator: "\n\n")
    }

    /// 75 → „1:15”, 3725 → „1:02:05”.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// 5025 → „1 godz. 23 min”, 754 → „12 min”, 42 → „42 s”.
    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) godz. \(minutes) min" : "\(hours) godz."
        }
        if minutes > 0 {
            return "\(minutes) min"
        }
        return "\(total) s"
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…:".contains(last)
    }
}

/// Bezpieczne nazwy plików do udostępniania.
enum FileNames {
    static func safe(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(80))
        return limited.isEmpty ? "Skryba" : limited
    }
}
