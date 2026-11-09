import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.language) private var language = SettingsDefault.language
    @AppStorage(SettingsKey.engine) private var engine = SettingsDefault.engine
    @AppStorage(SettingsKey.whisperModel) private var whisperModel = SettingsDefault.whisperModel
    @AppStorage(SettingsKey.farField) private var farField = SettingsDefault.farField
    @AppStorage(SettingsKey.autoCopy) private var autoCopy = SettingsDefault.autoCopy
    @AppStorage(SettingsKey.copyTimestamps) private var copyTimestamps = SettingsDefault.copyTimestamps
    @AppStorage(SettingsKey.vocabulary) private var vocabulary = SettingsDefault.vocabulary

    @State private var confirmModelDelete = false
    @State private var appleReport: EngineDiagnostics.Report?
    @State private var storageText = "…"

    var body: some View {
        NavigationStack {
            Form {
                transcriptionSection
                whisperSection
                vocabularySection
                copySection
                shareHelpSection
                aboutSection
            }
            .navigationTitle("Ustawienia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task(id: language) {
                appleReport = nil
                appleReport = await EngineDiagnostics.appleReport(for: language)
            }
            .onAppear {
                let bytes = app.store.totalSizeInBytes()
                storageText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
        }
    }

    // MARK: - Sekcje

    private var transcriptionSection: some View {
        Section {
            Picker("Język nagrań", selection: $language) {
                ForEach(Languages.all) { option in
                    Text(option.name).tag(option.code)
                }
            }
            Picker("Silnik", selection: $engine) {
                ForEach(EngineChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            engineStatus
            Toggle(isOn: $autoCopy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kopiuj automatycznie")
                    Text("Gotowy tekst od razu trafi do schowka.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Brand.indigo)
        } header: {
            Text("Transkrypcja")
        }
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch engine {
        case .apple:
            if let report = appleReport {
                StatusRow(
                    icon: icon(for: report.quality),
                    tint: tint(for: report.quality),
                    title: report.title,
                    detail: report.detail
                )
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Sprawdzam możliwości iPhone’a…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $farField) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nagrania z dystansu")
                    Text("Np. wykład z końca sali (dyktowanie na iPhonie).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Brand.indigo)
        case .whisper:
            let ready = isModelReady
            StatusRow(
                icon: ready ? "checkmark.seal.fill" : "arrow.down.circle.fill",
                tint: ready ? .green : Brand.indigo,
                title: ready ? "Whisper działa na tym iPhonie" : "Model pobierze się przy pierwszej transkrypcji",
                detail: "Najlepsza jakość dla polskiego, także przy dźwięku z końca sali. Działa bez internetu i nic nie wysyła poza telefon."
            )
        }
    }

    private var isModelReady: Bool {
        _ = app.modelRevision
        return WhisperModelHost.isDownloaded(whisperModel)
    }

    private var whisperSection: some View {
        Section {
            Picker("Model", selection: $whisperModel) {
                ForEach(WhisperModels.all) { option in
                    Text(verbatim: option.name).tag(option.id)
                }
            }
            if let progress = app.modelDownloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .tint(Brand.indigo)
                    Text(verbatim: "Pobieranie… \(Int((progress * 100).rounded()))% – nie zamykaj aplikacji")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isModelReady {
                Button("Usuń pobrany model", role: .destructive) {
                    confirmModelDelete = true
                }
            } else {
                Button {
                    app.downloadModel(whisperModel)
                } label: {
                    Label("Pobierz model teraz", systemImage: "arrow.down.circle")
                }
            }
        } header: {
            Text("Whisper na iPhonie")
        } footer: {
            Text(whisperFooter)
        }
        .confirmationDialog("Usunąć model z iPhone’a?", isPresented: $confirmModelDelete, titleVisibility: .visible) {
            Button("Usuń model", role: .destructive) {
                app.deleteModel(whisperModel)
            }
        } message: {
            Text("Zwolnisz miejsce. Przy następnej transkrypcji model pobierze się ponownie.")
        }
    }

    private var whisperFooter: String {
        let detail = WhisperModels.all.first { $0.id == whisperModel }?.detail ?? ""
        return detail + ". Model pobierasz raz (najlepiej przez Wi-Fi). Godzinny wykład to zwykle 5–15 minut transkrypcji – zostaw wtedy Skrybę otwartą."
    }

    private var vocabularySection: some View {
        Section {
            TextField("np. Krebs, mitochondrium, całka oznaczona", text: $vocabulary, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Słownik przedmiotu")
        } footer: {
            Text("Nazwiska i trudne terminy, oddzielone przecinkami. Pomagają rozpoznawaniu mowy Apple poprawnie je zapisać.")
        }
    }

    private var copySection: some View {
        Section {
            Toggle("Dodawaj znaczniki czasu [mm:ss]", isOn: $copyTimestamps)
                .tint(Brand.indigo)
        } header: {
            Text("Kopiowanie")
        } footer: {
            Text("Przydatne, gdy chcesz potem odsłuchać konkretny fragment wykładu.")
        }
    }

    private var shareHelpSection: some View {
        Section {
            HowToRow(number: 1, text: "Otwórz Dyktafon i wybierz nagranie.")
            HowToRow(number: 2, text: "Dotknij ••• (albo ikonę udostępniania) → „Udostępnij”.")
            HowToRow(number: 3, text: "Wybierz „Skryba” – aplikacja otworzy się i od razu zrobi transkrypcję. Opcja „Transkrybuj” zapisuje nagranie w tle.")
            HowToRow(number: 4, text: "Nie widzisz ikony? Przewiń rząd aplikacji do końca → „Więcej” i włącz Skrybę.")
        } header: {
            Text("Udostępnianie z Dyktafonu")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Wersja", value: appVersion)
            LabeledContent("Nagrania zajmują", value: storageText)
            LabeledContent("Liczba nagrań", value: "\(app.store.recordings.count)")
        } header: {
            Text("O aplikacji")
        } footer: {
            Text("Nagrania i transkrypcje są przechowywane tylko na tym iPhonie.")
        }
    }

    // MARK: - Pomocnicze

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func icon(for quality: EngineDiagnostics.Quality) -> String {
        switch quality {
        case .best: return "checkmark.seal.fill"
        case .good: return "checkmark.circle.fill"
        case .limited: return "wifi"
        case .unavailable: return "xmark.octagon.fill"
        }
    }

    private func tint(for quality: EngineDiagnostics.Quality) -> Color {
        switch quality {
        case .best: return .green
        case .good: return .green
        case .limited: return .orange
        case .unavailable: return .red
        }
    }
}

struct StatusRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

struct HowToRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Brand.gradient, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
