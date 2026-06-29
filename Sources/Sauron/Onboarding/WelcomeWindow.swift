import SwiftUI
import AppKit

/// First-run welcome window. A menu-bar agent (`LSUIElement`) has no Dock icon
/// and no normal window, so onboarding is a plain `NSWindow` hosting a SwiftUI
/// view, presented programmatically by `AppState` on first launch. It lets the
/// user point Sauron at their Obsidian vault and grant Accessibility before any
/// capture starts. Once dismissed it sets `Settings.didCompleteWelcome` so it
/// never appears again (the menu's "Change Obsidian folder…" handles later edits).
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    var isShowing: Bool { window != nil }

    /// Build and present the welcome window centered on screen. A menu-bar agent
    /// defaults to `.accessory` activation, which can't take key focus for a real
    /// window — flip to `.regular` while onboarding is on screen, then revert.
    func show() {
        guard window == nil, let state else { return }

        let hosting = NSHostingController(rootView: WelcomeView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Sauron"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Tear the window down and drop back to menu-bar-agent (`.accessory`) policy.
    func close() {
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The onboarding content. Three steps, top to bottom: choose vault folder,
/// grant Accessibility, optionally launch at login — then "Start logging".
struct WelcomeView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 18) {
                folderStep
                Divider()
                accessibilityStep
                Divider()
                launchStep
            }
            .padding(24)

            footer
        }
        .frame(width: 460)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to Sauron")
                .font(.title.weight(.semibold))
            Text("A quiet menu-bar logbook. Sauron watches the foreground "
                 + "window, summarizes what you worked on on-device, and writes "
                 + "one bullet to your Obsidian daily note. Nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    // MARK: - Steps

    private var folderStep: some View {
        stepRow(
            done: settings.hasChosenFolder,
            index: 1,
            title: "Choose your Obsidian daily-notes folder",
            detail: "Daily notes are written here as YYYY-MM-DD.md."
        ) {
            HStack(spacing: 8) {
                Text(folderLabel)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Choose…") { state.chooseDailyNotesDir() }
            }
        }
    }

    private var accessibilityStep: some View {
        stepRow(
            done: state.accessibilityTrusted,
            index: 2,
            title: "Grant Accessibility access",
            detail: "Sauron reads window text through the Accessibility API. "
                  + "This is the only permission it ever needs."
        ) {
            if state.accessibilityTrusted {
                Label("Accessibility access granted", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    Button("Grant access…") { state.requestAccessibility() }
                    Button("Open Settings…") { state.openAccessibilitySettings() }
                }
                Text("Already granted but still not detected? Remove Sauron from "
                     + "the Accessibility list, then add it again — a rebuilt app "
                     + "needs a fresh grant.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchStep: some View {
        stepRow(
            done: state.launchAtLogin,
            index: 3,
            title: "Launch at login",
            detail: "Optional — start Sauron automatically when you log in."
        ) {
            Toggle("Launch Sauron at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { _ in state.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if !state.accessibilityTrusted {
                    Text("You can grant access later from the menu, but capture "
                         + "won't start until you do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Start logging") { state.finishWelcome() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Building blocks

    /// One numbered step: a status bubble, a title + detail, and a custom control.
    @ViewBuilder
    private func stepRow<Control: View>(
        done: Bool,
        index: Int,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                control()
                    .padding(.top, 2)
            }
        }
    }

    private var folderLabel: String {
        (settings.dailyNotesDir as NSString).abbreviatingWithTildeInPath
    }
}
