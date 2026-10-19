import SwiftUI

/// Footage clusters and near-duplicate takes, computed from stored clip embeddings on every
/// appearance. Nothing here is persisted.
struct FootageGroupsView: View {
    @Environment(EditorViewModel.self) private var editor
    let assets: [MediaAsset]
    let onSelect: (String) -> Void

    @State private var groups: [FootageGroups.Group] = []
    @State private var nearDuplicates: [[String]] = []
    @State private var hasVectors = false

    private var managerReady: Bool {
        GemmaModelManager.shared.enabled && GemmaModelManager.shared.isReady
    }

    private var assetsById: [String: MediaAsset] {
        assets.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    var body: some View {
        Group {
            if !managerReady {
                emptyMessage(L10n.string("Enable EmbeddingGemma 2 in Settings to group footage."))
            } else if editor.searchIndex.indexingActive {
                VStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    emptyMessage(L10n.string("Indexing footage…"))
                }
            } else if !hasVectors {
                emptyMessage(L10n.string("Waiting for clip embeddings…"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                        groupsSection
                        similarSection
                    }
                    .padding(AppTheme.Spacing.lgXl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .task(id: editor.searchIndex.indexingActive) { await recompute() }
    }

    private func emptyMessage(_ text: String) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(text)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            sectionHeader("Groups", count: groups.count)
            if groups.isEmpty {
                emptyMessage(L10n.string("Not enough embedded footage to group yet."))
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: AppTheme.Spacing.sm)],
                    alignment: .leading,
                    spacing: AppTheme.Spacing.sm
                ) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        groupCard(group)
                    }
                }
            }
        }
    }

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            sectionHeader("Similar takes", count: nearDuplicates.count)
            ForEach(Array(nearDuplicates.enumerated()), id: \.offset) { _, members in
                HStack(spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        ForEach(members, id: \.self) { id in
                            memberThumb(id)
                        }
                    }
                    Text("\(members.count) similar takes")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer(minLength: 0)
                }
                .padding(AppTheme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
            }
        }
    }

    private func sectionHeader(_ title: String.LocalizationValue, count: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(L10n.string(title))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("\(count)")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    private func groupCard(_ group: FootageGroups.Group) -> some View {
        let shown = group.memberIDs.prefix(6)
        let rest = group.memberIDs.count - shown.count
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("\(group.memberIDs.count) clips")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: AppTheme.IconSize.xl + AppTheme.Spacing.xxs), spacing: AppTheme.Spacing.xxs)],
                alignment: .leading,
                spacing: AppTheme.Spacing.xxs
            ) {
                ForEach(Array(shown), id: \.self) { id in
                    memberThumb(id)
                }
                if rest > 0 {
                    Text("+\(rest)")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.xl, height: AppTheme.IconSize.xl)
                }
            }
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline))
    }

    private func memberThumb(_ id: String) -> some View {
        let asset = assetsById[id]
        return Button {
            onSelect(id)
        } label: {
            ZStack {
                if let image = asset?.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(AppTheme.Background.prominentColor)
                        .overlay(Image(systemName: "film")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor))
                }
            }
            .frame(width: AppTheme.IconSize.xl, height: AppTheme.IconSize.xl)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(asset?.name ?? id)
    }

    // MARK: - Compute

    private func recompute() async {
        guard managerReady, !editor.searchIndex.indexingActive else { return }
        let snapshot = assets
            .filter { $0.type == .video }
            .map { (id: $0.id, url: $0.url) }
        guard !snapshot.isEmpty else {
            groups = []
            nearDuplicates = []
            hasVectors = false
            return
        }
        let result = await Task.detached(priority: .utility) {
            () -> (groups: [FootageGroups.Group], nearDuplicates: [[String]], hasVectors: Bool) in
            let items: [(id: String, vector: [Float])] = snapshot.compactMap { entry in
                guard let key = GemmaIndexer.indexKey(sourceURL: nil, fallbackURL: entry.url),
                      let vector = ClipEmbedStore.load(key: key)?.clipVector,
                      !vector.isEmpty else { return nil }
                return (id: entry.id, vector: vector)
            }
            let k = max(2, Int((Double(items.count) / 2).squareRoot().rounded()))
            return (FootageGroups.groups(items: items, k: k),
                    FootageGroups.nearDuplicates(items: items),
                    !items.isEmpty)
        }.value
        guard !Task.isCancelled else { return }
        groups = result.groups
        nearDuplicates = result.nearDuplicates
        hasVectors = result.hasVectors
    }
}
