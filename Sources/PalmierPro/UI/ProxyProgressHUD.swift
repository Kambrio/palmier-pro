import SwiftUI

/// Bottom-corner progress for on-demand proxy generation. Mirrors MediaLoadHUD.
struct ProxyProgressHUD: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if editor.proxyManager.isGenerating {
            HStack(spacing: AppTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Creating proxies — \(editor.proxyManager.completed) of \(editor.proxyManager.total)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Button("Cancel") { editor.proxyManager.cancel() }
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
