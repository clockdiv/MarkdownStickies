import MarkdownStickiesCore
import SwiftUI

/// Centered sync card: progress with Cancel, then the result until dismissed.
/// Wording comes from `SyncStatusText`, shared with the iOS app.
struct SyncBannerOverlay: View {
    let state: SyncState
    var onCancel: () -> Void
    var onDismiss: () -> Void

    @State private var barPhase = false
    @State private var showSkipped = false

    private var isFinished: Bool { !state.isBusy }

    private var accent: Color {
        switch state {
        case .finished(.failed, _): return Color(red: 0.78, green: 0.22, blue: 0.22)
        case .finished(.cancelled, _): return Color(red: 0.85, green: 0.55, blue: 0.12)
        default: return Color(red: 0.18, green: 0.62, blue: 0.34)
        }
    }

    private var symbol: String? {
        switch state {
        case .finished(.completed, _): return "checkmark.circle.fill"
        case .finished(.cancelled, _): return "minus.circle.fill"
        case .finished(.failed, _): return "xmark.octagon.fill"
        default: return nil
        }
    }

    private var skippedLines: [String] {
        if case .finished(.completed(let summary), _) = state {
            return SyncStatusText.skippedLines(summary)
        }
        return []
    }

    var body: some View {
        ZStack {
            // Must fill + contentShape or list rows behind the card stay clickable.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if isFinished { onDismiss() }
                }

            VStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(SyncStatusText.title(state))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                let detail = SyncStatusText.detail(state)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !skippedLines.isEmpty {
                    DisclosureGroup(isExpanded: $showSkipped) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(skippedLines, id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 140)
                        .textSelection(.enabled)
                    } label: {
                        Text("Skipped (\(skippedLines.count))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .tint(.white)
                }

                if state.isBusy {
                    indeterminateBar
                        .padding(.top, 4)
                    if case .waitingForConfirmation = state {
                        EmptyView()
                    } else {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.borderedProminent)
                            .tint(.white.opacity(0.25))
                            .foregroundStyle(.white)
                    }
                } else {
                    Button("OK", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.25))
                        .foregroundStyle(.white)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 380)
            .background(accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.easeOut(duration: 0.15), value: state)
        .onAppear { barPhase = true }
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
