import SwiftUI
import UIKit

// MARK: - Style

/// Przycisk, który lekko się „wciska”.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Tło karty: zaokrąglony prostokąt w kolorze systemowym.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

/// Szklana kapsuła (Liquid Glass na iOS 26, materiał na starszych).
struct GlassCapsule: ViewModifier {
    #if compiler(>=6.2)
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
    #else
    func body(content: Content) -> some View {
        content.background(.regularMaterial, in: Capsule())
    }
    #endif
}

extension View {
    func card(padding: CGFloat = 18) -> some View {
        modifier(CardBackground(padding: padding))
    }

    func glassCapsule() -> some View {
        modifier(GlassCapsule())
    }
}

// MARK: - Małe komponenty

struct Chip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 5
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .stroke(Brand.indigo.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(Brand.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
        .frame(width: size, height: size)
    }
}

/// Ikona stanu nagrania na liście.
struct StatusIcon: View {
    let status: Recording.Status
    let progress: Double?

    var body: some View {
        ZStack {
            switch status {
            case .done:
                Circle().fill(Brand.gradient)
                Image(systemName: "text.quote")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            case .transcribing:
                Circle().fill(Brand.indigo.opacity(0.08))
                ProgressRing(progress: progress ?? 0, lineWidth: 4, size: 46)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.indigo)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            case .pending:
                Circle().fill(Brand.indigo.opacity(0.10))
                Image(systemName: "hourglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.indigo)
            case .recording:
                Circle().fill(Brand.coral.opacity(0.15))
                Image(systemName: "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.coral)
            case .failed:
                Circle().fill(Color.orange.opacity(0.15))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 46, height: 46)
    }
}

// MARK: - Komunikaty

struct ToastOverlay: View {
    let toast: Toast?

    var body: some View {
        ZStack {
            if let toast {
                HStack(spacing: 10) {
                    Image(systemName: toast.icon)
                        .font(.headline)
                        .foregroundStyle(Brand.indigo)
                    Text(toast.message)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassCapsule()
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                .padding(.top, 6)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: toast?.id)
        .allowsHitTesting(false)
    }
}

struct ImportingOverlay: View {
    var message = "Dodaję nagranie…"

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .transition(.opacity)
    }
}

// MARK: - Udostępnianie plików

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
