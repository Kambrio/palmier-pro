import AppKit

extension TimelineView {
    /// RMB submenu to tag a clip's footage with Shot Library labels (Key, Hero, B-roll, …),
    /// checkmarked when already applied. Works before analysis — toggling creates a minimal shot
    /// entry that a later analysis refines while preserving the label.
    func shotLabelSubmenu(for clip: Clip) -> NSMenu? {
        guard clip.mediaType == .video else { return nil }
        let current = Set(editor.shotLibrary.entry(assetId: clip.mediaRef)?.labels ?? [])
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for def in ShotLabels.all {
            let item = NSMenuItem(title: def.title, action: #selector(performToggleShotLabel(_:)), keyEquivalent: "")
            item.target = self
            item.state = current.contains(def.id) ? .on : .off
            item.image = NSImage(systemSymbolName: def.systemImage, accessibilityDescription: nil)
            item.representedObject = ["mediaRef": clip.mediaRef, "label": def.id] as [String: Any]
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func performToggleShotLabel(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let mediaRef = info["mediaRef"] as? String,
              let label = info["label"] as? String else { return }
        editor.shotLibraryManager.toggleLabelEnsuringEntry(assetId: mediaRef, label)
        needsDisplay = true
    }
}
