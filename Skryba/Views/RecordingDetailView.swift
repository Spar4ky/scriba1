import SwiftUI
import UIKit

/// Szczegóły nagrania: odtwarzacz, transkrypcja, kopiowanie i udostępnianie.
struct RecordingDetailView: View {
    let recordingID: UUID

    @Environment(AppModel.self) private var app
    @State private var player = AudioPlayerModel()
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isEditing = false
    @State private var shareItem: ShareItem?
    @State private var confirmDelete = false
    @State private var copyCount = 0

    var body: some View {
        Group {
            if let recording = app.store.recording(id: recordingID) {
                content(for: recording)
            } else {
                ContentUnavailableView("Nagranie usunięte", systemImage: "trash")
            }
        }
        .background(Color(.systemGroupedBackground))
        .onDisappear {
            player.pause()
        }
    }

    @ViewBuilder
    private func content(for recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(recording: recording)
                PlayerCard(player: player)
                TranscriptSection(
                    recording: recording,
                    live: app.transcriber.live[recording.id],
                    player: player
                )
            }
            // Na szerokim ekranie iPada tekst nie rozlewa się na całą szerokość – łatwiej się czyta.
            .frame(maxWidth: DetailLayout.maxContentWidth, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu(for: recording)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if recording.hasTranscript && recording.status != .transcribing {
                CopyBar(
                    shareText: TranscriptFormatter.plainText(for: recording, timestamps: false),
                    title: recording.title
                ) {
                    app.copyTranscript(recording)
                    copyCount += 1
                }
            }
        }
        .task(id: recording.audioFileName) {
            player.load(url: app.store.audioURL(for: recording))
        }
        .sensoryFeedback(.success, trigger: copyCount)
        .alert("Zmień nazwę", isPresented: $isRenaming) {
            TextField("Nazwa nagrania", text: $draftTitle)
            Button("Zapisz") {
                app.rename(recording.id, to: draftTitle)
            }
            Button("Anuluj", role: .cancel) {}
        }
        .sheet(isPresented: $isEditing) {
            TranscriptEditor(recording: recording)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .confirmationDialog("Usunąć to nagranie?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Usuń nagranie i transkrypcję", role: .destructive) {
                app.delete(recording.id)
            }
            Button("Anuluj", role: .cancel) {}
        }
    }

    private func moreMenu(for recording: Recording) -> some View {
        let busy = recording.status == .transcribing || recording.status == .recording
        return Menu {
            Button("Zmień nazwę", systemImage: "pencil") {
                draftTitle = recording.title
                isRenaming = true
            }
            if recording.hasTranscript {
                Button("Edytuj tekst", systemImage: "square.and.pencil") {
                    isEditing = true
                }
                Button("Udostępnij jako plik .txt", systemImage: "doc.text") {
                    shareTextFile(recording)
                }
            }
            Button("Udostępnij nagranie audio", systemImage: "waveform") {
                shareAudioFile(recording)
            }
            Menu("Transkrybuj ponownie", systemImage: "arrow.clockwise") {
                ForEach(Languages.all) { option in
                    Button(option.name) {
                        app.retranscribe(recording.id, language: option.code)
                    }
                }
            }
            .disabled(busy)
            Divider()
            Button("Usuń", systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Więcej")
    }

    private func shareTextFile(_ recording: Recording) {
        let text = TranscriptFormatter.plainText(for: recording, timestamps: SettingsSnapshot.current().copyTimestamps)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(FileNames.safe(recording.title))
            .appendingPathExtension("txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(items: [url])
        } catch {
            app.presentError("Nie udało się przygotować pliku: \(error.localizedDescription)")
        }
    }

    private func shareAudioFile(_ recording: Recording) {
        let source = app.store.audioURL(for: recording)
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(FileNames.safe(recording.title))
            .appendingPathExtension(ext)
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
            shareItem = ShareItem(items: [url])
        } catch {
            app.presentError("Nie udało się przygotować nagrania: \(error.localizedDescription)")
        }
    }
}

enum DetailLayout {
    /// Maksymalna szerokość treści (wygodna długość wiersza na iPadzie).
    static let maxContentWidth: CGFloat = 760
}

// MARK: - Nagłówek

struct DetailHeader: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recording.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(icon: "calendar", text: recording.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                    Chip(icon: "clock", text: TranscriptFormatter.durationText(recording.duration))
                    Chip(icon: "globe", text: Languages.name(for: recording.language))
                    if let engine = recording.engineLabel {
                        Chip(icon: "cpu", text: engine)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Dolny pasek kopiowania

struct CopyBar: View {
    let shareText: String
    let title: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCopy) {
                Label("Kopiuj całość", systemImage: "doc.on.doc.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Brand.indigo)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            ShareLink(item: shareText, subject: Text(title)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Udostępnij tekst")
        }
        .frame(maxWidth: DetailLayout.maxContentWidth)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Edycja tekstu

struct TranscriptEditor: View {
    let recording: Recording

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.body)
                    .fontDesign(.default)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                if recording.editedText != nil {
                    Button(role: .destructive) {
                        app.saveEditedText(recording.id, text: nil)
                        dismiss()
                    } label: {
                        Label("Przywróć oryginalną transkrypcję", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.vertical, 12)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Edycja tekstu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        app.saveEditedText(recording.id, text: text)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                text = TranscriptFormatter.plainText(for: recording, timestamps: false)
            }
        }
    }
}
