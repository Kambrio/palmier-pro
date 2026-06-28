import Foundation

extension EditorViewModel {
    /// Hands a seeded prompt to the in-app assistant: fills the chat draft, closes the library/graph
    /// sheets, and reveals + focuses the chat panel so the user can review and send (or keep editing).
    func handToAssistant(prompt: String) {
        agentService.draft = prompt
        agentService.mentions.removeAll()
        showStoryGraph = false
        showShotLibrary = false
        agentPanelVisible = true
        focusedPanel = .agent
    }
}
