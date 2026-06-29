import AppKit
import ApplicationServices

/// Wires up the two event sources (NSWorkspace app activations + a per-app
/// AXObserver for in-app context changes) plus the optional safety poll, and
/// emits a `Capture` for each interesting moment. Event-driven — no busy polling.
@MainActor
final class ActivityMonitor {

    private let onCapture: (Capture) -> Void

    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var observedElement: AXUIElement?
    private var safetyTimer: Timer?

    private(set) var isRunning = false

    /// The AX notifications we watch on the currently-active app.
    private static let watchedNotifications: [String] = [
        kAXFocusedWindowChangedNotification as String,
        kAXTitleChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
    ]

    init(onCapture: @escaping (Capture) -> Void) {
        self.onCapture = onCapture
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppSwitch()
            }
        }

        if Config.safetyPollInterval > 0 {
            let timer = Timer.scheduledTimer(withTimeInterval: Config.safetyPollInterval,
                                             repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.captureNow()
                }
            }
            timer.tolerance = Config.safetyPollInterval * 0.2
            safetyTimer = timer
        }

        // Attach to the app that's already frontmost at startup.
        handleAppSwitch()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil

        safetyTimer?.invalidate()
        safetyTimer = nil

        tearDownAXObserver()
    }

    // MARK: - App switch → rebuild the per-app AXObserver

    private func handleAppSwitch() {
        guard isRunning else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        if pid != observedPID {
            rebuildAXObserver(for: pid)
        }
        captureNow()
    }

    private func rebuildAXObserver(for pid: pid_t) {
        tearDownAXObserver()

        var observer: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &observer)
        guard err == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.watchedNotifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)

        axObserver = observer
        observedPID = pid
        observedElement = appElement
    }

    private func tearDownAXObserver() {
        if let observer = axObserver {
            if let element = observedElement {
                for notification in Self.watchedNotifications {
                    AXObserverRemoveNotification(observer, element, notification as CFString)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        axObserver = nil
        observedElement = nil
        observedPID = 0
    }

    // MARK: - Capture

    /// Called from AXObserver callbacks (in-app context changes) and timers.
    fileprivate func handleAXEvent() {
        guard isRunning else { return }
        captureNow()
    }

    private func captureNow() {
        guard let capture = WindowReader.readFrontmost() else { return }
        onCapture(capture)
    }
}

/// C callback for the AXObserver. Fires on the run loop the source was added to
/// (the main run loop), so it's safe to hop onto the main actor.
private func axObserverCallback(_ observer: AXObserver,
                                _ element: AXUIElement,
                                _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let monitor = Unmanaged<ActivityMonitor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handleAXEvent()
    }
}
