import SwiftUI

/// The menu shown from the menu-bar icon.
struct MenuContent: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Text(statusText)

        Divider()

        captureControls

        Divider()

        folderControls

        Divider()

        launchToggle

        Divider()

        Button("Quit Sauron") { state.quit() }
            .keyboardShortcut("q")
    }

    // MARK: - Sections

    @ViewBuilder
    private var captureControls: some View {
        switch state.status {
        case .needsAccessibility:
            Button("Grant Accessibility access…") { state.togglePause() }
        case .logging:
            Button("Pause") { state.togglePause() }
        case .paused:
            Button("Resume") { state.togglePause() }
        }

        Button("Open today's note") { state.openTodaysNote() }
        Button("Flush now") { state.flush() }
    }

    @ViewBuilder
    private var folderControls: some View {
        Text("Obsidian folder: \(folderLabel)")
        Button("Change Obsidian folder…") { state.chooseDailyNotesDir() }
    }

    private var launchToggle: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { _ in state.toggleLaunchAtLogin() }
        ))
    }

    // MARK: - Labels

    /// Show the folder name with `~` abbreviation so the menu stays compact.
    private var folderLabel: String {
        (settings.dailyNotesDir as NSString).abbreviatingWithTildeInPath
    }

    private var statusText: String {
        switch state.status {
        case .needsAccessibility:
            return "⚠︎ Needs Accessibility access"
        case .logging:
            return "Logging · \(state.pendingCaptures) pending"
        case .paused:
            return "Paused"
        }
    }
}
