import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ShareCandidate {
    let provider: NSItemProvider
    let typeIdentifier: String
    let title: String?
}

enum ShareError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "Nie udało się odczytać udostępnionego pliku."
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case working
        case saved(count: Int, title: String)
        case failed(String)
    }

    private(set) var phase: Phase = .working

    func start(with context: NSExtensionContext?) {
        let candidates = ShareModel.audioAttachments(in: context)
        guard !candidates.isEmpty else {
            phase = .failed("Nie znaleziono pliku audio do przekazania.")
            return
        }
        Task {
            await save(candidates)
        }
    }

    private func save(_ candidates: [ShareCandidate]) async {
        var titles: [String] = []
        var lastError: Error?
        for candidate in candidates {
            do {
                let manifest = try await ShareModel.copyToInbox(candidate)
                titles.append(manifest.title ?? "Nagranie")
            } catch {
                lastError = error
            }
        }
        guard let first = titles.first else {
            phase = .failed(lastError?.localizedDescription ?? "Nie udało się zapisać nagrania.")
            return
        }
        phase = .saved(count: titles.count, title: first)
        let body = titles.count == 1
            ? "Dotknij, żeby zrobić transkrypcję „\(first)”."
            : "Dotknij, żeby zrobić transkrypcję: \(Plural.recordings(titles.count))."
        Notifier.post(title: "Nagranie czeka w Skrybie", body: body, delay: 1)
    }

    static func audioAttachments(in context: NSExtensionContext?) -> [ShareCandidate] {
        guard let items = context?.inputItems as? [NSExtensionItem] else { return [] }
        var result: [ShareCandidate] = []
        for item in items {
            let itemTitle = item.attributedTitle?.string ?? item.attributedContentText?.string
            for provider in item.attachments ?? [] {
                guard let type = preferredType(for: provider) else { continue }
                let suggested = provider.suggestedName.map { ($0 as NSString).deletingPathExtension }
                let title = [suggested, itemTitle]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                result.append(ShareCandidate(provider: provider, typeIdentifier: type, title: title))
            }
        }
        return result
    }

    private static func preferredType(for provider: NSItemProvider) -> String? {
        let identifiers = provider.registeredTypeIdentifiers
        if let audio = identifiers.first(where: { UTType($0)?.conforms(to: .audio) == true }) {
            return audio
        }
        if let media = identifiers.first(where: { UTType($0)?.conforms(to: .audiovisualContent) == true }) {
            return media
        }
        return identifiers.first { $0.localizedCaseInsensitiveContains("audio") }
    }

    nonisolated static func copyToInbox(_ candidate: ShareCandidate) async throws -> InboxManifest {
        let provider = candidate.provider
        let typeIdentifier = candidate.typeIdentifier
        let title = candidate.title
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InboxManifest, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareError.unreadable)
                    return
                }
                do {
                    let manifest = try Inbox.store(fileAt: url, title: title)
                    continuation.resume(returning: manifest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ShareRootView: View {
    let model: ShareModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
            Spacer(minLength: 8)
            icon
            texts
            Spacer(minLength: 8)
            Button(action: onClose) {
                Text(model.phase == .working ? "Anuluj" : "Gotowe")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fontDesign(.rounded)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.phase {
        case .working:
            ProgressView()
                .controlSize(.large)
                .frame(width: 96, height: 96)
        case .saved:
            ZStack {
                Circle()
                    .fill(Brand.gradient)
                    .frame(width: 96, height: 96)
                    .shadow(color: Brand.indigo.opacity(0.35), radius: 16, y: 6)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .failed:
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var texts: some View {
        switch model.phase {
        case .working:
            Text("Przekazuję nagranie do Skryby…")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        case .saved(let count, let title):
            VStack(spacing: 10) {
                Text(headline(count: count, title: title))
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Otwórz aplikację Skryba albo dotknij powiadomienia – transkrypcja zacznie się automatycznie.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text("Nie udało się")
                    .font(.title3.weight(.bold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func headline(count: Int, title: String) -> String {
        if count == 1 {
            return "„\(title)” czeka w Skrybie"
        }
        let verb = Plural.polish(count, one: "czeka", few: "czekają", many: "czeka")
        return Plural.recordings(count) + " " + verb + " w Skrybie"
    }
}
