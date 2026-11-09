import SwiftUI
import UIKit

/// Sekcja transkrypcji – zależnie od stanu: postęp, błąd albo tekst.
struct TranscriptSection: View {
    let recording: Recording
    let live: TranscriptionManager.LiveState?
    let player: AudioPlayerModel

    @Environment(AppModel.self) private var app

    var body: some View {
        switch recording.status {
        case .recording:
            InfoCard(
                icon: "mic.fill",
                tint: Brand.coral,
                title: "Trwa nagrywanie",
                message: "Transkrypcja zacznie się automatycznie po zakończeniu nagrania."
            )

        case .pending:
            VStack(spacing: 16) {
                PendingCard(isQueued: app.transcriber.isQueuedOrActive(recording.id)) {
                    app.retry(recording.id)
                }
                if !recording.partialSegments.isEmpty {
                    TranscriptBody(
                        paragraphs: TranscriptFormatter.paragraphs(from: recording.partialSegments),
                        editedText: nil,
                        player: player,
                        isPreview: true
                    )
                }
            }

        case .transcribing:
            VStack(spacing: 16) {
                TranscribingCard(
                    live: live,
                    onSwitchToFast: { app.switchToFastModel(for: recording.id) },
                    onCancel: { app.cancelTranscription(recording.id) }
                )
                let preview = live?.preview ?? recording.partialSegments
                if !preview.isEmpty {
                    TranscriptBody(
                        paragraphs: TranscriptFormatter.paragraphs(from: preview),
                        editedText: nil,
                        player: player,
                        isPreview: true
                    )
                }
            }

        case .failed:
            VStack(spacing: 16) {
                FailedCard(
                    message: recording.errorMessage ?? "Nieznany błąd.",
                    onRetry: { app.retry(recording.id) },
                    onSettings: { app.isSettingsPresented = true }
                )
                if recording.hasTranscript {
                    TranscriptBody(
                        paragraphs: TranscriptFormatter.paragraphs(from: recording.segments),
                        editedText: recording.editedText,
                        player: player,
                        isPreview: false
                    )
                }
            }

        case .done:
            if recording.hasTranscript {
                TranscriptBody(
                    paragraphs: TranscriptFormatter.paragraphs(from: recording.segments),
                    editedText: recording.editedText,
                    player: player,
                    isPreview: false
                )
            } else {
                InfoCard(
                    icon: "waveform",
                    tint: .orange,
                    title: "Nie wykryto mowy",
                    message: "W nagraniu nie udało się rozpoznać słów. Sprawdź język (menu ••• → Transkrybuj ponownie) albo spróbuj silnika Whisper w Ustawieniach."
                )
            }
        }
    }
}

// MARK: - Tekst

struct TranscriptBody: View {
    let paragraphs: [TranscriptParagraph]
    let editedText: String?
    let player: AudioPlayerModel
    let isPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(isPreview ? "Podgląd na żywo" : "Transkrypcja", systemImage: isPreview ? "text.bubble" : "text.alignleft")
                    .font(.headline)
                    .foregroundStyle(isPreview ? Brand.indigo : Color.primary)
                Spacer()
                Text(statistics)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let editedText {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                    Text("Tekst edytowany ręcznie")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Text(editedText)
                    .font(.body)
                    .fontDesign(.default)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(paragraphs) { paragraph in
                    ParagraphView(
                        paragraph: paragraph,
                        isActive: isActive(paragraph)
                    ) {
                        player.play(from: paragraph.start)
                    }
                }
            }
        }
        .card()
        .opacity(isPreview ? 0.8 : 1)
    }

    private var statistics: String {
        let text = editedText ?? paragraphs.map(\.text).joined(separator: " ")
        return Plural.words(TranscriptFormatter.wordCount(text))
    }

    private func isActive(_ paragraph: TranscriptParagraph) -> Bool {
        guard player.isPlaying || player.currentTime > 0 else { return false }
        let time = player.currentTime
        guard time >= paragraph.start else { return false }
        let nextIndex = paragraph.id + 1
        if nextIndex < paragraphs.count {
            return time < paragraphs[nextIndex].start
        }
        return time <= paragraph.end + 1
    }
}

struct ParagraphView: View {
    let paragraph: TranscriptParagraph
    let isActive: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                HStack(spacing: 4) {
                    Image(systemName: isActive ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(TranscriptFormatter.clock(paragraph.start))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(Brand.indigo)
                .background(Brand.indigo.opacity(isActive ? 0.2 : 0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Odtwórz od \(TranscriptFormatter.clock(paragraph.start))")

            Text(paragraph.text)
                .font(.body)
                .fontDesign(.default)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, isActive ? 8 : 0)
        .padding(.horizontal, isActive ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isActive ? Brand.indigo.opacity(0.07) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }
}

// MARK: - Karty stanu

struct TranscribingCard: View {
    let live: TranscriptionManager.LiveState?
    let onSwitchToFast: () -> Void
    let onCancel: () -> Void

    /// Model jeszcze się pobiera albo przygotowuje (transkrypcja nie ruszyła).
    private var isWaitingForModel: Bool {
        ModelStatus.shared.isBusy && live?.engine == nil
    }

    var body: some View {
        let progress = min(max(live?.progress ?? 0, 0), 1)
        let percent = Int((progress * 100).rounded())
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    ProgressRing(progress: progress)
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.indigo)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transkrypcja w toku")
                        .font(.headline)
                    Text(live?.stage ?? live?.engine ?? "Przygotowanie…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(verbatim: "\(percent)%")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Brand.indigo)
                    .contentTransition(.numericText())
                    .animation(.default, value: percent)
            }
            if isWaitingForModel {
                ModelPreparationView(status: ModelStatus.shared, onSwitchToFast: onSwitchToFast)
            } else {
                ProgressView(value: progress)
                    .tint(Brand.indigo)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: DeviceNames.isPad ? "ipad" : "iphone")
                Text("Zostaw Skrybę otwartą do końca – ekran nie zgaśnie sam. Jeśli wyjdziesz, transkrypcja wznowi się po powrocie.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button("Anuluj transkrypcję", role: .destructive, action: onCancel)
                .font(.subheadline.weight(.semibold))
        }
        .card()
    }
}

/// Pobieranie i przygotowanie modelu Whisper – z licznikiem czasu, żeby było widać, że coś się dzieje.
struct ModelPreparationView: View {
    let status: ModelStatus
    /// Przycisk „Użyj modelu Szybki” (tylko przy transkrypcji, nie w Ustawieniach).
    var allowsSwitch = true
    var onSwitchToFast: () -> Void = {}

    private var modelName: String {
        WhisperModels.name(for: status.variant ?? "")
    }

    private var canSwitchToFast: Bool {
        allowsSwitch && status.variant == WhisperModels.accurate
    }

    var body: some View {
        switch status.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction)
                    .tint(Brand.violet)
                Text(verbatim: "Pobieram model \(modelName): \(Int((fraction * 100).rounded()))%. To jednorazowe – najlepiej przez Wi-Fi.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.indigo)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .preparing(let firstTime):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(status.phaseStartedAt))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(verbatim: "Przygotowuję model \(modelName) · \(TranscriptFormatter.clock(elapsed))")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Brand.indigo)
                    }
                    Text(firstTime
                         ? "Pierwsze uruchomienie: \(DeviceNames.nominative) dopasowuje model do swojego procesora. Dzieje się to tylko raz i zwykle trwa 1–5 minut (model Dokładny czasem do kilkunastu). Kolejne transkrypcje ruszą od razu."
                         : "Ładuję model do pamięci – to kilka sekund.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if canSwitchToFast && elapsed > 150 {
                        Button(action: onSwitchToFast) {
                            Label("Za długo? Użyj modelu Szybki", systemImage: "hare.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(Brand.indigo)
                    }
                }
            }
        case .idle, .ready, .failed:
            EmptyView()
        }
    }
}

struct PendingCard: View {
    let isQueued: Bool
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Czeka na transkrypcję")
                    .font(.headline)
                Text(isQueued ? "Zacznie się za chwilę." : "Wstrzymana – dotknij, aby wznowić.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !isQueued {
                Button("Start", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
            }
        }
        .card()
    }
}

struct FailedCard: View {
    let message: String
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transkrypcja nie powiodła się", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Spróbuj ponownie", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                Button("Ustawienia", action: onSettings)
                    .buttonStyle(.bordered)
            }
        }
        .card()
    }
}

struct InfoCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

// MARK: - Odtwarzacz

struct PlayerCard: View {
    let player: AudioPlayerModel

    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    player.isScrubbing = editing
                }
            )
            .tint(Brand.indigo)
            .disabled(!player.isReady)

            HStack {
                Text(TranscriptFormatter.clock(player.currentTime))
                Spacer()
                Text("-" + TranscriptFormatter.clock(max(0, player.duration - player.currentTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Menu {
                    ForEach(rates, id: \.self) { rate in
                        Button {
                            player.setRate(rate)
                        } label: {
                            if rate == player.rate {
                                Label(rateLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(rateLabel(rate))
                            }
                        }
                    }
                } label: {
                    Text(rateLabel(player.rate))
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .frame(width: 64, alignment: .leading)

                Spacer()

                Button {
                    player.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .accessibilityLabel("15 sekund do tyłu")

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(Brand.gradient, in: Circle())
                        .shadow(color: Brand.indigo.opacity(0.35), radius: 10, y: 4)
                }
                .padding(.horizontal, 22)
                .accessibilityLabel(player.isPlaying ? "Pauza" : "Odtwórz")

                Button {
                    player.skip(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                }
                .accessibilityLabel("15 sekund do przodu")

                Spacer()

                Color.clear.frame(width: 64, height: 1)
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(Brand.indigo)
            .disabled(!player.isReady)
        }
        .card()
    }

    private func rateLabel(_ rate: Float) -> String {
        Double(rate).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
