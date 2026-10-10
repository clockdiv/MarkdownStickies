import MarkdownStickiesCore
import SwiftUI

/// Centered sync card — live progress, then result until dismissed.
struct SyncBannerOverlay: View {
    let feedback: SyncFeedback
    var onDismiss: () -> Void

    @State private var barPhase = false

    private var accent: Color {
        switch feedback.kind {
        case .progress, .success: return Color(red: 0.18, green: 0.62, blue: 0.34)
        case .warning: return Color(red: 0.85, green: 0.55, blue: 0.12)
        case .failure: return Color(red: 0.78, green: 0.22, blue: 0.22)
        }
    }

    private var symbol: String {
        switch feedback.kind {
        case .progress: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var dismissLabel: String {
        feedback.debugCode == "sync:await-mac-merge" ? "Sync Later" : "OK"
    }

    var body: some View {
        ZStack {
            // Must fill + contentShape or list rows behind the card stay clickable.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard feedback.isTerminal else { return }
                    onDismiss()
                }

            VStack(spacing: 14) {
                if feedback.kind != .progress {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(feedback.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Text(feedback.message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let item = feedback.currentItem, !item.isEmpty {
                    Text(item)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 8)
                }

                if feedback.kind == .progress {
                    indeterminateBar
                        .padding(.top, 4)
                }

                if let detail = feedback.detail, feedback.kind != .success, feedback.kind != .progress {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if feedback.isTerminal {
                    // Keep machine codes for failures / incomplete syncs; hide for normal conflict/success.
                    if feedback.kind == .failure
                        || feedback.debugCode == "sync:ack-partial"
                        || feedback.debugCode == "sync:no-ack"
                    {
                        Text(feedback.debugCode)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Button(dismissLabel, action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.25))
                        .foregroundStyle(.white)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 360)
            .background(accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.easeOut(duration: 0.2), value: feedback.debugCode)
        .animation(.easeOut(duration: 0.15), value: feedback.message)
        .animation(.easeOut(duration: 0.15), value: feedback.currentItem)
        .onAppear { barPhase = true }
        .onChange(of: feedback.kind) { _, kind in
            barPhase = (kind == .progress)
        }
    }

    private var indeterminateBar: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - geo.size.width * 0.38, 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.22))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.95))
                    .frame(width: geo.size.width * 0.38)
                    .offset(x: barPhase ? travel : -geo.size.width * 0.1)
            }
        }
        .frame(height: 5)
        .clipShape(Capsule(style: .continuous))
        .animation(
            .easeInOut(duration: 1.05).repeatForever(autoreverses: true),
            value: barPhase
        )
        .accessibilityLabel("Sync in progress")
    }
}
