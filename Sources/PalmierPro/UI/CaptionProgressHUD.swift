import SwiftUI

/// App-level, non-modal progress panel for caption generation. Mounted on the editor
/// root so it's visible whatever the active tab and whoever started the job (Captions
/// tab or the agent's add_captions). Driven by `EditorViewModel.captionJob`.
struct CaptionProgressHUD: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if let job = editor.captionJob {
            panel(job)
                .padding(AppTheme.Spacing.lg)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func panel(_ job: CaptionJob) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let error = job.errorMessage {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppTheme.Status.errorColor)
                    Text("Caption generation failed")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                }
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Dismiss") { editor.cancelCaptionGeneration() } }
            } else {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(job.label)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
                if job.total > 0 {
                    ProgressView(value: job.fraction)
                        .frame(maxWidth: .infinity)
                }
                HStack { Spacer(); Button("Cancel") { editor.cancelCaptionGeneration() } }
            }
        }
        .frame(maxWidth: AppTheme.ComponentSize.captionHudMaxWidth, alignment: .leading)
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.md).strokeBorder(AppTheme.Border.subtleColor))
        )
        .shadow(AppTheme.Shadow.md)
    }
}
