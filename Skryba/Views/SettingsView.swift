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
    @State private var backgroundRevision = 0
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
                diagnosticsSection
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
                    Text("Sprawdzam możliwości \(DeviceNames.genitive)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $farField) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nagrania z dystansu")
                    Text("Np. wykład z końca sali (dyktowanie na \(DeviceNames.locative)).")
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
                title: ready ? "Whisper działa na tym \(DeviceNames.locative)" : "Model trzeba raz pobrać i przygotować",
                detail: "Najlepsza jakość dla polskiego, także przy dźwięku z końca sali. Działa bez internetu i nic nie wysyła poza urządzenie."
            )
        }
    }

    /// Model pobrany i choć raz uruchomiony (kolejne transkrypcje ruszają od razu).
    private var isModelReady: Bool {
        _ = app.modelRevision
        return WhisperModelHost.isDownloaded(whisperModel) && WhisperModelHost.isPrepared(whisperModel)
    }

    private var isModelDownloaded: Bool {
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
            if ModelStatus.shared.isBusy {
                ModelPreparationView(status: ModelStatus.shared, allowsSwitch: false)
                    .padding(.vertical, 4)
            } else if isModelReady {
                Label("Model gotowy do pracy", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Usuń pobrany model", role: .destructive) {
                    confirmModelDelete = true
                }
            } else {
                Button {
                    app.prepareModel(whisperModel)
                } label: {
                    Label(isModelDownloaded ? "Przygotuj model teraz" : "Pobierz i przygotuj model", systemImage: "arrow.down.circle")
                }
                if isModelDownloaded {
                    Button("Usuń pobrany model", role: .destructive) {
                        confirmModelDelete = true
                    }
                }
            }
        } header: {
            Text("Whisper na \(DeviceNames.locative)")
        } footer: {
            Text(whisperFooter)
        }
        .confirmationDialog("Usunąć model z \(DeviceNames.genitive)?", isPresented: $confirmModelDelete, titleVisibility: .visible) {
            Button("Usuń model", role: .destructive) {
                app.deleteModel(whisperModel)
            }
        } message: {
            Text("Zwolnisz miejsce. Przy następnej transkrypcji model pobierze się ponownie.")
        }
    }

    private var whisperFooter: String {
        let detail = WhisperModels.all.first { $0.id == whisperModel }?.detail ?? ""
        return detail + ". Model pobierasz i przygotowujesz raz (najlepiej przez Wi-Fi, przy otwartej Skrybie) – pierwsze przygotowanie trwa kilka minut, potem transkrypcja rusza od razu. Godzinny wykład to zwykle 5–15 minut transkrypcji."
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
            HowToRow(number: 1, text: "W Dyktafonie wybierz nagranie → Udostępnij → „Skryba”.")
            HowToRow(number: 2, text: "Jeśli Skryba poprosi o folder (tylko za pierwszym razem): wejdź do „\(DeviceNames.onMyDevice)” → „Skryba” i dotknij „Otwórz”.")
            HowToRow(number: 3, text: "Otwórz Skrybę albo dotknij powiadomienia – nagranie doda się samo i od razu ruszy transkrypcja.")
            HowToRow(number: 4, text: "Zawsze działa też: Udostępnij → „Zachowaj w Plikach” → „\(DeviceNames.onMyDevice)” → „Skryba” → Zapisz.")
        } header: {
            Text("Udostępnianie z Dyktafonu")
        } footer: {
            Text("Nie widzisz Skryby w arkuszu udostępniania? Przewiń rząd aplikacji do końca → „Więcej” i włącz ją.")
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
            Text("Nagrania i transkrypcje są przechowywane tylko na tym \(DeviceNames.locative).")
        }
    }

    private var backgroundStatus: String {
        _ = backgroundRevision
        return BackgroundWorkGuard.statusDescription
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Urządzenie", value: DeviceInfo.summary)
            LabeledContent("Wspólny kontener", value: AppGroup.identifier == nil ? "brak – działa folder Skryba" : "działa")
            LabeledContent("Transkrypcja w tle", value: backgroundStatus)
            if !BackgroundWorkGuard.isAllowed {
                Button("Sprawdź pracę w tle jeszcze raz") {
                    BackgroundWorkGuard.reset()
                    backgroundRevision += 1
                }
            }
            NavigationLink {
                DiagnosticsLogView()
            } label: {
                Label("Dziennik zdarzeń", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("Diagnostyka")
        } footer: {
            Text("Gdy coś nie działa, otwórz dziennik i zrób zrzut ekranu – widać w nim, co i kiedy się działo.")
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

/// Dziennik zdarzeń (pobieranie i przygotowanie modelu, transkrypcje, importy, błędy).
struct DiagnosticsLogView: View {
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "Skryba \(DeviceInfo.appVersion)\n\(DeviceInfo.summary)\nApp Group: \(AppGroup.statusDescription)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: text.isEmpty ? "Dziennik jest pusty." : text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle("Dziennik zdarzeń")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copied ? "Skopiowano" : "Kopiuj") {
                    UIPasteboard.general.string = "Skryba \(DeviceInfo.appVersion) · \(DeviceInfo.summary)\n\n" + text
                    copied = true
                }
            }
        }
        .onAppear {
            text = DiagnosticsLog.shared.text
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
