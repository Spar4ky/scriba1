import Foundation

/// Prosty dziennik zdarzeń: pobieranie i ładowanie modelu, transkrypcje, importy, błędy.
/// Widać go w Ustawieniach → Diagnostyka – zrzut ekranu pokazuje, co się działo.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private let url: URL
    private var lines: [String]
    private let maxLines = 400

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "dd.MM HH:mm:ss"
        return formatter
    }()

    private init() {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        url = base.appendingPathComponent("diagnostics.log")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
    }

    static func add(_ message: String) {
        shared.append(message)
    }

    func append(_ message: String) {
        let line = DiagnosticsLog.formatter.string(from: Date()) + "  " + message
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
        try? FileManager.default.removeItem(at: url)
    }
}

/// Opis urządzenia do dziennika i ekranu diagnostyki.
enum DeviceInfo {
    static var memoryText: String {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return String(format: "%.1f GB RAM", gigabytes)
    }

    static var systemText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let system = DeviceNames.isPad ? "iPadOS" : "iOS"
        return "\(system) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    static var summary: String {
        "\(DeviceNames.machineIdentifier) · \(systemText) · \(memoryText)"
    }
}
