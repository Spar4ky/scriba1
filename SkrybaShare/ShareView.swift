import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ShareCandidate {
    let provider: NSItemProvider
    let typeIdentifier: String
    let title: String?
}

/// Dokąd rozszerzenie odkłada nagranie.
enum ShareDestination {
    /// Wspólny kontener (App Group) – najwygodniej, bez pytań.
    case inbox
    /// Folder „Skryba” w aplikacji Pliki – gdy instalacja nie ma App Group.
    case folder(URL)
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
        case needsFolder(wrongPick: Bool)
        case failed(String)
    }

    private(set) var phase: Phase = .working

    @ObservationIgnored private var candidates: [ShareCandidate] = []
    /// Ustawiane przez kontroler rozszerzenia.
    @ObservationIgnored var presentFolderPicker: (() -> Void)?
    @ObservationIgnored var openContainingApp: (() -> Bool)?

    func start(with context: NSExtensionContext?) {
        candidates = ShareModel.audioAttachments(in: context)
        guard !candidates.isEmpty else {
            phase = .failed("Nie znaleziono pliku audio do przekazania.")
            return
        }
        if AppGroup.inboxURL != nil {
            Task { await deliver(to: .inbox) }
        } else if let folder = DropFolderBookmark.resolve() {
            Task { await deliver(to: .folder(folder)) }
        } else {
            phase = .needsFolder(wrongPick: false)
        }
    }

    func chooseFolder() {
        presentFolderPicker?()
    }

    func folderPicked(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        let isSkryba = DropFolder.isSkrybaFolder(url)
        if isSkryba {
            DropFolderBookmark.save(url)
        }
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
        guard isSkryba else {
            phase = .needsFolder(wrongPick: true)
            return
        }
        phase = .working
        Task { await deliver(to: .folder(url)) }
    }

    private func deliver(to destination: ShareDestination) async {
        var folderAccess: URL?
        if case .folder(let folder) = destination, folder.startAccessingSecurityScopedResource() {
            folderAccess = folder
        }
        var titles: [String] = []
        var lastError: Error?
        for candidate in candidates {
            do {
                let title = try await ShareModel.copy(candidate, to: destination)
                titles.append(title)
            } catch {
                lastError = error
            }
        }
        folderAccess?.stopAccessingSecurityScopedResource()

        guard let first = titles.first else {
            if case .folder = destination {
                // Zapamiętany folder przestał działać – następnym razem zapytamy o niego ponownie.
                DropFolderBookmark.forget()
                phase = .failed("Nie udało się zapisać nagrania w folderze Skryba. Spróbuj jeszcze raz – Skryba poprosi o wskazanie folderu od nowa.")
            } else {
                phase = .failed(lastError?.localizedDescription ?? "Nie udało się zapisać nagrania.")
            }
            return
        }

        phase = .saved(count: titles.count, title: first)
        let body = titles.count == 1
            ? "Dotknij, żeby zrobić transkrypcję „\(first)”."
            : "Dotknij, żeby zrobić transkrypcję: \(Plural.recordings(titles.count))."
        Notifier.post(title: "Nagranie czeka w Skrybie", body: body, delay: 1)

        // Spróbuj od razu otworzyć Skrybę (nie każda wersja iOS na to pozwala –
        // wtedy zostaje powiadomienie i ekran „Gotowe”).
        _ = openContainingApp?()
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

    /// Kopiuje jeden plik do wybranego miejsca. Zwraca tytuł nagrania.
    nonisolated static func copy(_ candidate: ShareCandidate, to destination: ShareDestination) async throws -> String {
        let provider = candidate.provider
        let typeIdentifier = candidate.typeIdentifier
        let title = candidate.title
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareError.unreadable)
                    return
                }
                do {
                    switch destination {
                    case .inbox:
                        let manifest = try Inbox.store(fileAt: url, title: title)
                        continuation.resume(returning: manifest.title ?? "Nagranie")
                    case .folder(let folder):
                        let saved = try DropFolder.deliver(fileAt: url, title: title, into: folder)
                        continuation.resume(returning: saved.deletingPathExtension().lastPathComponent)
                    }
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
            buttons
        }
        .padding(24)
        .frame(maxWidth: 560)
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
        case .needsFolder:
            ZStack {
                Circle()
                    .fill(Brand.indigo.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Brand.indigo)
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
                Text("Otwórz Skrybę albo dotknij powiadomienia – transkrypcja zacznie się sama.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .needsFolder(let wrongPick):
            VStack(spacing: 12) {
                Text(wrongPick ? "To nie jest folder Skryby" : "Wskaż folder Skryby – tylko raz")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Dotknij przycisku poniżej, wejdź do „\(DeviceNames.onMyDevice)” → „Skryba” i dotknij „Otwórz”. Skryba zapamięta ten folder i następnym razem wszystko pójdzie samo.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text("Nie udało się")
                    .font(.title3.weight(.bold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .needsFolder:
            VStack(spacing: 12) {
                primaryButton(title: "Wskaż folder Skryba", systemImage: "folder") {
                    model.chooseFolder()
                }
                Button("Anuluj", action: onClose)
                    .font(.headline)
                    .padding(.vertical, 6)
            }
        case .working:
            primaryButton(title: "Anuluj", systemImage: nil, action: onClose)
        default:
            primaryButton(title: "Gotowe", systemImage: nil, action: onClose)
        }
    }

    private func primaryButton(title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func headline(count: Int, title: String) -> String {
        if count == 1 {
            return "„\(title)” czeka w Skrybie"
        }
        let verb = Plural.polish(count, one: "czeka", few: "czekają", many: "czeka")
        return Plural.recordings(count) + " " + verb + " w Skrybie"
    }
}
