import MarkdownStickiesCore
import SwiftUI

/// Centered sync result card — stays until the user dismisses or starts another sync.
struct SyncBannerOverlay: View {
    let feedback: SyncFeedback
    var onDismiss: () -> Void

    private var accent: Color {
        switch feedback.kind {
        case .success: return Color(red: 0.18, green: 0.62, blue: 0.34)
        case .warning: return Color(red: 0.85, green: 0.55, blue: 0.12)
        case .failure: return Color(red: 0.78, green: 0.22, blue: 0.22)
        }
    }

    private var symbol: String {
        switch feedback.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)

                Text(feedback.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Text(feedback.message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = feedback.detail, feedback.kind != .success {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text(feedback.debugCode)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))

                Button("OK", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.25))
                    .foregroundStyle(.white)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 360)
            .background(accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.easeOut(duration: 0.2), value: feedback.debugCode)
    }
}
