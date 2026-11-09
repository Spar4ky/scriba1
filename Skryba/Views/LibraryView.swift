import SwiftUI
import UIKit

struct LibrarySection: Identifiable {
    let id: String
    let items: [Recording]

    static func make(from recordings: [Recording]) -> [LibrarySection] {
        let calendar = Calendar.current
        var sections: [LibrarySection] = []
        for recording in recordings {
            let title: String
            if calendar.isDateInToday(recording.createdAt) {
                title = "Dzisiaj"
            } else if calendar.isDateInYesterday(recording.createdAt) {
                title = "Wczoraj"
            } else {
                let formatted = recording.createdAt.formatted(.dateTime.month(.wide).year())
                title = formatted.prefix(1).uppercased() + formatted.dropFirst()
            }
            if let last = sections.last, last.id == title {
                sections[sections.count - 1] = LibrarySection(id: title, items: last.items + [recording])
            } else {
                sections.append(LibrarySection(id: title, items: [recording]))
            }
        }
        return sections
    }
}

/// Lista nagrań – lewa kolumna na iPadzie, ekran główny na iPhonie.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText = ""
    @State private var pendingDeletion: Recording?

    var body: some View {
        content
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Skryba")
            .searchable(text: $searchText, prompt: "Szukaj w nagraniach i tekstach")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        app.isImporterPresented = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityLabel("Importuj plik audio")

                    Button {
                        app.isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityLabel("Ustawienia")
                }
            }
            .safeAreaInset(edge: .bottom) {
                RecordButtonBar()
            }
            .confirmationDialog(
                "Usunąć to nagranie?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { recording in
                Button("Usuń nagranie i transkrypcję", role: .destructive) {
                    app.delete(recording.id)
                }
                Button("Anuluj", role: .cancel) {}
            } message: { recording in
                Text("„\(recording.title)” zniknie z tego \(DeviceNames.genitive).")
            }
    }

    private var filtered: [Recording] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return app.store.recordings }
        return app.store.recordings.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.store.recordings.isEmpty {
            EmptyLibraryView()
        } else {
            let sections = LibrarySection.make(from: filtered)
            if sections.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(selection: selection) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { recording in
                                row(for: recording)
                            }
                        } header: {
                            Text(section.id)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Zaznaczenie listy = otwarte nagranie. Na iPhonie wybór otwiera ekran nagrania,
    /// a powrót czyści zaznaczenie; na iPadzie nagranie pokazuje się obok listy.
    private var selection: Binding<UUID?> {
        Binding(
            get: { app.selectedID },
            set: { app.selectedID = $0 }
        )
    }

    private func row(for recording: Recording) -> some View {
        let isSelected = horizontalSizeClass == .regular && app.selectedID == recording.id
        return ZStack {
            // Niewidoczny link (bez strzałki „>”) – cały wiersz otwiera nagranie.
            NavigationLink(value: recording.id) {
                EmptyView()
            }
            .opacity(0)
            RecordingCard(recording: recording, live: app.transcriber.live[recording.id], isSelected: isSelected)
        }
        .hoverEffect(.highlight)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = recording
            } label: {
                Label("Usuń", systemImage: "trash")
            }
            if recording.hasTranscript {
                Button {
                    app.copyTranscript(recording)
                } label: {
                    Label("Kopiuj", systemImage: "doc.on.doc")
                }
                .tint(Brand.indigo)
            }
        }
        .contextMenu {
            if recording.hasTranscript {
                Button("Kopiuj całą transkrypcję", systemImage: "doc.on.doc") {
                    app.copyTranscript(recording)
                }
            }
            Button("Usuń", systemImage: "trash", role: .destructive) {
                pendingDeletion = recording
            }
        }
    }
}

struct RecordingCard: View {
    let recording: Recording
    let live: TranscriptionManager.LiveState?
    var isSelected = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StatusIcon(status: recording.status, progress: live?.progress)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(recording.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(TranscriptFormatter.clock(recording.duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                detail
            }
        }
        .card(padding: 16)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Brand.indigo, lineWidth: 2.5)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let date = recording.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        var parts = [date, Languages.name(for: recording.language)]
        if recording.source == .shared {
            parts.append("z Dyktafonu")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var detail: some View {
        switch recording.status {
        case .transcribing:
            let percent = Int(((live?.progress ?? 0) * 100).rounded())
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(max(live?.progress ?? 0, 0), 1))
                    .tint(Brand.indigo)
                Text(verbatim: "Transkrypcja… \(percent)%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.indigo)
            }
            .padding(.top, 4)
        case .pending:
            Text("Czeka na transkrypcję")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        case .recording:
            Text("Trwa nagrywanie…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.coral)
                .padding(.top, 2)
        case .failed:
            Text(recording.errorMessage ?? "Transkrypcja nie powiodła się")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.top, 2)
        case .done:
            if let preview = recording.previewText {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            } else {
                Text("Nie wykryto mowy")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }
}

struct RecordButtonBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            Task { await app.beginRecording() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: app.recorder.isActive ? "waveform" : "mic.fill")
                Text(app.recorder.isActive ? "Wróć do nagrywania" : "Nagraj")
            }
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 34)
            .padding(.vertical, 17)
            .background(Brand.recordGradient, in: Capsule())
            .shadow(color: Brand.crimson.opacity(0.4), radius: 18, y: 8)
        }
        .buttonStyle(PressableButtonStyle())
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel("Rozpocznij nagrywanie")
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Brand.gradient)
                        .opacity(0.14)
                        .frame(width: 132, height: 132)
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(Brand.gradient)
                }
                .padding(.top, 36)

                VStack(spacing: 8) {
                    Text("Nagraj swój pierwszy wykład")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Skryba nagra dźwięk i od razu zamieni go na tekst, który skopiujesz jednym dotknięciem.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 14) {
                    TipRow(icon: "mic.fill", text: "Dotknij „Nagraj” na dole ekranu.")
                    TipRow(icon: "square.and.arrow.up", text: "Albo w Dyktafonie: wybierz nagranie → Udostępnij → Skryba.")
                    TipRow(icon: "folder.fill", text: "Możesz też zapisać nagranie w Plikach: \(DeviceNames.onMyDevice) → Skryba. Doda się samo.")
                    TipRow(icon: "doc.on.doc.fill", text: "Gotowy tekst skopiujesz przyciskiem „Kopiuj całość”.")
                }
                .card()
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
