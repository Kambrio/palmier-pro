import SwiftUI

/// App-level, non-modal progress panel for lazy media preparation (thumbnails / waveforms /
/// metadata). Auto-dismisses when the prep queue drains. Driven by `EditorViewModel.mediaPrep`.
struct MediaLoadHUD: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if let prep = editor.mediaPrep {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Preparing media — \(prep.completed) of \(prep.total)")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
                ProgressView(value: prep.fraction)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: AppTheme.ComponentSize.captionHudMaxWidth, alignment: .leading)
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
