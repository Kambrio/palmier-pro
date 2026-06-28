import SwiftUI

struct TimelineContainerView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let headerView = TimelineHeaderView(editor: editor)
        headerView.frame = NSRect(x: 0, y: 0, width: Layout.trackHeaderWidth, height: 0)
        headerView.autoresizingMask = [.height]
        container.addSubview(headerView)

        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScroller?.controlSize = .mini
        scrollView.verticalScroller?.controlSize = .mini

        let timelineView = TimelineView(editor: editor)
        timelineView.autoresizingMask = []
        scrollView.documentView = timelineView
        headerView.requestCanvasRedraw = { [weak timelineView] in timelineView?.needsDisplay = true }

        scrollView.frame = NSRect(x: Layout.trackHeaderWidth, y: 0, width: 0, height: 0)
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = AppTheme.Border.primary.cgColor
        border.frame = NSRect(x: Layout.trackHeaderWidth - 1, y: 0, width: 1, height: 0)
        border.autoresizingMask = [.height]
        container.addSubview(border)

        context.coordinator.headerView = headerView
        context.coordinator.timelineView = timelineView
        context.coordinator.scrollView = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let renderState = RenderState(
            revision: editor.timelineRenderRevision,
            zoomScale: editor.zoomScale,
            selectedClipIds: editor.selectedClipIds,
            selectedTimelineRange: editor.selectedTimelineRange,
            pendingReplacements: editor.pendingReplacements,
            generatingAssetIds: Set(editor.mediaAssets.lazy.filter(\.isGenerating).map(\.id))
        )

        if context.coordinator.needsRender(for: renderState) {
            context.coordinator.timelineView?.updateContentSize()
            context.coordinator.timelineView?.needsDisplay = true
            context.coordinator.headerView?.needsDisplay = true
        }

        if editor.isPlaying,
           let timelineView = context.coordinator.timelineView,
           let scrollView = context.coordinator.scrollView {
            let geo = timelineView.geometry
            let playheadX = geo.xForFrame(editor.activeFrame)
            let visibleRect = scrollView.contentView.bounds
            let margin: CGFloat = 60

            if playheadX < visibleRect.origin.x + margin ||
               playheadX > visibleRect.origin.x + visibleRect.width - margin {
                let newOriginX = max(0, playheadX - visibleRect.width * 0.25)
                scrollView.contentView.setBoundsOrigin(
                    NSPoint(x: newOriginX, y: visibleRect.origin.y)
                )
            }
        }

        // Restore last-session scroll once (after the content is sized at the restored zoom).
        if let pending = editor.pendingTimelineScroll {
            editor.pendingTimelineScroll = nil
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.applyScrollRestore(pending, editor: editor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct RenderState: Equatable {
        let revision: Int
        let zoomScale: Double
        let selectedClipIds: Set<String>
        let selectedTimelineRange: TimelineRangeSelection?
        let pendingReplacements: Set<String>
        let generatingAssetIds: Set<String>
    }

    final class Coordinator: NSObject {
        var headerView: TimelineHeaderView?
        var timelineView: TimelineView?
        var scrollView: NSScrollView?
        private var renderState: RenderState?

        func needsRender(for next: RenderState) -> Bool {
            defer { renderState = next }
            return renderState != next
        }

        @MainActor @objc func scrollViewBoundsChanged(_ notification: Notification) {
            timelineView?.needsDisplay = true
            timelineView?.updatePlayheadLayer()
            guard let origin = scrollView?.contentView.bounds.origin else { return }
            headerView?.setBoundsOrigin(NSPoint(x: 0, y: origin.y))
            headerView?.needsDisplay = true
            // Mirror the live offset so it can be persisted as last-session view state.
            timelineView?.editor.timelineScrollX = origin.x
            timelineView?.editor.timelineScrollY = origin.y
        }

        /// Applies a restored scroll offset, retrying until the scroll view is laid out and the
        /// document is sized (so clamping uses real dimensions).
        @MainActor func applyScrollRestore(_ point: CGPoint, editor: EditorViewModel, attempt: Int = 0) {
            guard let timelineView, let scrollView else { return }
            timelineView.updateContentSize()
            let docSize = timelineView.frame.size
            let visible = scrollView.contentView.bounds.size
            if visible.width <= 1, attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.applyScrollRestore(point, editor: editor, attempt: attempt + 1)
                }
                return
            }
            let x = min(max(0, point.x), max(0, docSize.width - visible.width))
            let y = min(max(0, point.y), max(0, docSize.height - visible.height))
            scrollView.contentView.setBoundsOrigin(NSPoint(x: x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            timelineView.needsDisplay = true
            editor.timelineScrollX = x
            editor.timelineScrollY = y
        }

        @MainActor @objc func clipViewFrameChanged(_ notification: Notification) {
            timelineView?.updateContentSize()
            timelineView?.updatePlayheadLayer()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
