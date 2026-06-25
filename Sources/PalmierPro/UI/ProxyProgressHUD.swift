import SwiftUI

/// Bottom-corner progress for on-demand proxy generation. Mirrors MediaLoadHUD.
struct ProxyProgressHUD: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if editor.proxyManager.isGenerating {
            // Tick each second so the ETA counts down between completions.
            // (Qualified: the app has its own AppKit `TimelineView`.)
            SwiftUI.TimelineView(PeriodicTimelineSchedule(from: Date(), by: 1)) { context in
                hud(now: context.date)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func hud(now: Date) -> some View {
        let mgr = editor.proxyManager
        return HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Creating proxies — \(mgr.completed) of \(mgr.total)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let subtitle = subtitle(mgr, now: now) {
                    Text(subtitle)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            Button("Cancel") { mgr.cancel() }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.md).strokeBorder(AppTheme.Border.subtleColor))
        )
        .shadow(AppTheme.Shadow.md)
        .padding(AppTheme.Spacing.lg)
    }

    private func subtitle(_ mgr: ProxyManager, now: Date) -> String? {
        var parts: [String] = []
        if let eta = mgr.eta(asOf: now) { parts.append("~\(Self.formatETA(eta)) left") }
        if let bytes = mgr.estimatedRunBytes {
            parts.append("~\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) total")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}
