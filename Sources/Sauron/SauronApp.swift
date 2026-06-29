import SwiftUI
import AppKit
import ServiceManagement

@main
struct SauronApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.isPaused ? "eye.slash" : "eye")
                .opacity(state.isPaused ? 0.4 : 1.0)
        }
    }
}

/// Owns the buffer, the monitor, the flush timer, and the permission/launch
/// state. Everything user-facing reads from here.
@MainActor
final class AppState: ObservableObject {
    enum Status {
        case needsAccessibility
        case logging
        case paused
    }

    @Published private(set) var status: Status = .needsAccessibility
    @Published private(set) var pendingLines = 0
    @Published var launchAtLogin = false
    /// Live Accessibility-trust flag, surfaced to the welcome screen so its
    /// "Grant access" step flips to a checkmark the moment the user grants it.
    @Published private(set) var accessibilityTrusted = false

    var isPaused: Bool { status == .paused }

    private let rawLog = RawLog()
    private var monitor: ActivityMonitor!
    private var flushTimer: Timer?
    private var permissionTimer: Timer?
    private var welcomeController: WelcomeWindowController?
    private var welcomePollTimer: Timer?
    /// Guards against overlapping summary flushes (summarization is async).
    private var summarizing = false

    init() {
        monitor = ActivityMonitor { [weak self] capture in
            self?.ingest(capture)
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        accessibilityTrusted = Permissions.isTrusted()

        if Settings.shared.didCompleteWelcome {
            beginPermissionFlow()
        } else {
            // First run: present the welcome window before any capture starts.
            // Deferred to the next runloop tick so NSApp is fully up before we
            // flip activation policy and order a window front.
            DispatchQueue.main.async { [weak self] in
                self?.presentWelcome()
            }
        }
    }

    // MARK: - Welcome / first run

    private func presentWelcome() {
        let controller = WelcomeWindowController(state: self)
        welcomeController = controller
        controller.show()
        startWelcomePoll()
    }

    /// Poll trust state while the welcome window is up so the Accessibility step
    /// reflects a grant without the user having to click anything again.
    private func startWelcomePoll() {
        welcomePollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accessibilityTrusted = Permissions.isTrusted()
            }
        }
        timer.tolerance = 0.3
        welcomePollTimer = timer
    }

    /// Surface the system Accessibility prompt from the welcome screen.
    func requestAccessibility() {
        Permissions.promptForTrust()
        accessibilityTrusted = Permissions.isTrusted()
    }

    /// Jump to System Settings › Privacy & Security › Accessibility.
    func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    /// "Start logging" — close onboarding, remember it's done, and hand off to
    /// the normal permission flow (which starts capture if already trusted, or
    /// waits on the grant otherwise).
    func finishWelcome() {
        Settings.shared.didCompleteWelcome = true
        welcomePollTimer?.invalidate()
        welcomePollTimer = nil
        welcomeController?.close()
        welcomeController = nil
        beginPermissionFlow()
    }

    // MARK: - Permission flow

    private func beginPermissionFlow() {
        accessibilityTrusted = Permissions.isTrusted()
        if accessibilityTrusted {
            startLogging()
        } else {
            status = .needsAccessibility
            Permissions.promptForTrust()
            // Poll trust state lightly until granted, then start.
            let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.accessibilityTrusted = Permissions.isTrusted()
                    if self.accessibilityTrusted {
                        self.permissionTimer?.invalidate()
                        self.permissionTimer = nil
                        self.startLogging()
                    }
                }
            }
            timer.tolerance = 0.5
            permissionTimer = timer
        }
    }

    // MARK: - Capture lifecycle

    private func startLogging() {
        status = .logging
        monitor.start()
        startFlushTimer()
    }

    private func ingest(_ capture: Capture) {
        guard status == .logging else { return }
        if rawLog.append(capture) {
            pendingLines = rawLog.lineCount
            // Line-count trigger: summarize once enough has accumulated.
            if rawLog.lineCount >= Config.summaryLineThreshold {
                summarizeFlush()
            }
        }
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        // Time trigger: roll the buffer up on the interval if anything's pending.
        let timer = Timer.scheduledTimer(withTimeInterval: Config.summaryInterval,
                                         repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.summarizeFlush()
            }
        }
        timer.tolerance = Config.summaryInterval * 0.1
        flushTimer = timer
    }

    // MARK: - Menu actions

    func togglePause() {
        switch status {
        case .logging:
            // Roll up whatever's buffered on pause.
            summarizeFlush()
            monitor.stop()
            flushTimer?.invalidate()
            flushTimer = nil
            status = .paused
        case .paused:
            startLogging()
        case .needsAccessibility:
            beginPermissionFlow()
        }
    }

    /// Public entry for the "Flush now" menu item.
    func flush() {
        summarizeFlush()
    }

    /// Drain the pending raw chunk, summarize it on-device, and append one
    /// timestamped bullet to the daily note. The raw lines are cleared up front
    /// so captures arriving during the async summary accumulate into the next
    /// chunk. Re-entrancy is guarded so overlapping triggers can't double-write.
    private func summarizeFlush() {
        guard !summarizing else { return }
        guard !rawLog.isEmpty else { return }

        let snapshot = rawLog.readAll()
        let timestamp = rawLog.firstTimestamp ?? Date()
        rawLog.clear()
        pendingLines = 0
        guard !snapshot.isEmpty else { return }

        summarizing = true
        Task {
            let summary = await Summarizer.summarize(snapshot) ?? Summarizer.fallback(snapshot)
            DailyNoteWriter.appendSummary(summary, at: timestamp, to: Settings.shared.dailyNotesDir)
            summarizing = false
        }
    }

    func openTodaysNote() {
        let dir = Settings.shared.dailyNotesDir
        // Make sure today's file exists, then roll up anything pending into it.
        DailyNoteWriter.ensureNoteExists(for: Date(), in: dir)
        summarizeFlush()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let path = URL(fileURLWithPath: dir)
            .appendingPathComponent("\(formatter.string(from: Date())).md")
        NSWorkspace.shared.open(path)
    }

    /// Present a folder picker so the user can set their Obsidian daily-notes
    /// folder. The chosen path is persisted via `Settings` and used on the next
    /// flush. Pending captures are rolled up first so they land in the old folder.
    func chooseDailyNotesDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose your Obsidian daily-notes folder"
        panel.directoryURL = URL(fileURLWithPath: Settings.shared.dailyNotesDir)

        // A menu-bar agent (LSUIElement) isn't active by default; the panel
        // won't come to the front without this.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Flush pending captures to the current folder before switching.
        flush()
        Settings.shared.dailyNotesDir = url.path
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
        } catch {
            // Re-sync with reality on failure.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    func quit() {
        monitor.stop()
        flushTimer?.invalidate()
        flushTimer = nil

        // Best effort: summarize the final chunk, then terminate. The raw lines
        // survive on disk if this is interrupted and are recovered next launch.
        guard !summarizing, !rawLog.isEmpty else {
            NSApplication.shared.terminate(nil)
            return
        }
        let snapshot = rawLog.readAll()
        let timestamp = rawLog.firstTimestamp ?? Date()
        let dir = Settings.shared.dailyNotesDir
        rawLog.clear()
        Task {
            let summary = await Summarizer.summarize(snapshot) ?? Summarizer.fallback(snapshot)
            DailyNoteWriter.appendSummary(summary, at: timestamp, to: dir)
            NSApplication.shared.terminate(nil)
        }
    }
}
