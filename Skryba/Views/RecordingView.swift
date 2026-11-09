import SwiftUI
import UIKit

/// Pełnoekranowy ekran nagrywania.
struct RecordingView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.language) private var language = SettingsDefault.language
    @State private var title = ""
    @State private var confirmDiscard = false
    @State private var pulse = false
    @FocusState private var titleFocused: Bool

    private var recorder: Recorder { app.recorder }
    private var isPaused: Bool { recorder.state == .paused }

    private var pulseAnimation: Animation {
        if isPaused {
            return Animation.default
        }
        return Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    }

    var body: some View {
        ZStack {
            Brand.nightGradient
                .ignoresSafeArea()
                .onTapGesture { titleFocused = false }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                VStack(spacing: 26) {
                    statusPill
                    Text(TranscriptFormatter.clock(recorder.elapsed))
                        .font(.system(size: 70, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.default, value: Int(recorder.elapsed))
                    LiveWaveform(levels: recorder.levels, isActive: !isPaused)
                        .frame(height: 120)
                        .padding(.horizontal, 8)
                }
                Spacer(minLength: 12)
                titleField
                controls
                    .padding(.top, 30)
                Text("Możesz zablokować ekran albo przejść do innej aplikacji – nagrywanie trwa w tle, nawet kilka godzin. Nie zamykaj tylko Skryby w przełączniku aplikacji (przesunięcie w górę) – to zatrzymuje nagrywanie.\(DeviceNames.isPad ? " Skróty: ⌘P pauza, ⌘⏎ zakończ." : "")")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 22)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            app.startRecording()
            pulse = true
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.state)
        .confirmationDialog("Odrzucić to nagranie?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Odrzuć nagranie", role: .destructive) {
                app.discardRecording()
            }
            Button("Nagrywaj dalej", role: .cancel) {}
        } message: {
            Text("Dźwięk zostanie usunięty i nie da się go odzyskać.")
        }
    }

    // MARK: - Części

    private var header: some View {
        HStack {
            Button("Anuluj") {
                confirmDiscard = true
            }
            .font(.body.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))

            Spacer()

            Menu {
                ForEach(Languages.all) { option in
                    Button {
                        language = option.code
                    } label: {
                        if option.code == language {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text(Languages.name(for: language))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isPaused ? Color.yellow : Brand.coral)
                .frame(width: 10, height: 10)
                .opacity(!isPaused && pulse ? 0.25 : 1)
                .animation(pulseAnimation, value: pulse)
            Text(isPaused ? "PAUZA" : "NAGRYWANIE")
                .font(.footnote.weight(.bold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    private var titleField: some View {
        TextField(
            "",
            text: $title,
            prompt: Text("Nazwa, np. Anatomia – wykład 5").foregroundStyle(.white.opacity(0.4))
        )
        .focused($titleFocused)
        .submitLabel(.done)
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                recorder.togglePause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .keyboardShortcut("p", modifiers: .command)
            .accessibilityLabel(isPaused ? "Wznów nagrywanie" : "Wstrzymaj nagrywanie")

            Button {
                titleFocused = false
                app.stopRecording(title: title)
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 4)
                        .frame(width: 100, height: 100)
                    Circle()
                        .fill(Brand.recordGradient)
                        .frame(width: 84, height: 84)
                        .shadow(color: Brand.crimson.opacity(0.6), radius: 18)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 30, height: 30)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Zakończ i zrób transkrypcję")

            VStack(spacing: 4) {
                Image(systemName: "text.badge.checkmark")
                    .font(.title3.weight(.semibold))
                Text("Stop =\ntekst")
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.45))
            .frame(width: 66, height: 66)
            .accessibilityHidden(true)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Animowany „oscyloskop” z poziomów głośności mikrofonu.
struct LiveWaveform: View {
    let levels: [CGFloat]
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 3
            let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Color.white.opacity(0.25 + 0.75 * Double(index) / Double(count)))
                        .frame(width: barWidth, height: max(4, level * geometry.size.height))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .opacity(isActive ? 1 : 0.4)
        .animation(.linear(duration: 0.05), value: levels)
    }
}
