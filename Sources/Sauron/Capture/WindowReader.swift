import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the foreground window's app, title, URL, and body text via the
/// Accessibility API. No Screen Recording, no automation, no network.
enum WindowReader {

    // MARK: - Public entry point

    /// Read the current frontmost application's focused window. Returns nil for
    /// blocklisted apps (captured nothing) or when no readable window exists.
    static func readFrontmost() -> Capture? {
        // OS-level secret signal (strongest, app-agnostic): when ANY app has
        // secure event input enabled, a password is being entered right now —
        // the same flag password managers set to defeat keyloggers. Suspend
        // capture entirely. This fails closed and needs no app/site enumeration,
        // so it catches secrets in apps the blocklist never heard of.
        if Config.pauseDuringSecureInput, IsSecureEventInputEnabled() { return nil }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = frontApp.bundleIdentifier

        // Blocklist: capture nothing, not even the title.
        if let bundleID, Config.blocklistBundleIDs.contains(bundleID) { return nil }

        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? bundleID ?? "Unknown"

        let isElectron = detectElectron(bundleID: bundleID, app: frontApp)
        if isElectron { enableChromiumA11y(pid: pid) }

        let appElement = AXUIElementCreateApplication(pid)
        guard let focusedWindow = copyElement(appElement, kAXFocusedWindowAttribute) else {
            return nil
        }

        let title = copyString(focusedWindow, kAXTitleAttribute)
        let url = browserURL(window: focusedWindow, bundleID: bundleID)

        // URL-level gate: never capture body text from banking / finance / health
        // / government pages, which the bundle-ID blocklist can't reach.
        let host = url.flatMap { URL(string: $0)?.host }
        let sensitivePage = SensitiveFilter.looksSensitiveHost(host)

        var body: String? = nil
        if Config.captureBodyText, !sensitivePage {
            body = collectText(focusedWindow)
            // Electron's a11y tree builds asynchronously: the first walk can come
            // back empty even though content is present. Sleep briefly and retry once.
            if isElectron, (body == nil || body!.isEmpty) {
                Thread.sleep(forTimeInterval: Config.electronRetryDelay)
                body = collectText(focusedWindow)
            }
        }

        // Final layer: content redaction. Mask anything that looks like a card
        // number, SSN, account/routing number, secret, or token before it can be
        // staged. Applied to both title and body — secrets leak into titles too
        // (e.g. an untitled doc echoing pasted text).
        return Capture(timestamp: Date(),
                       app: appName,
                       title: SensitiveFilter.redact(title),
                       url: url,
                       body: SensitiveFilter.redact(body))
    }

    // MARK: - AX attribute helpers

    /// Copy an attribute that is itself an AXUIElement (e.g. the focused window).
    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Copy a string-valued attribute.
    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            let s = value as! CFString as String
            return s.isEmpty ? nil : s
        }
        return nil
    }

    /// Copy the children array of an element.
    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard err == .success, let value else { return [] }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as! [AXUIElement])
    }

    // MARK: - Subtree text walk

    /// Recursively walk the focused window's AX subtree, concatenating visible
    /// text. Caps total output, guards recursion depth, and bails early once the
    /// cap is hit so a large DOM can't stall the walk.
    static func collectText(_ root: AXUIElement) -> String? {
        var lines: [String] = []
        var charCount = 0
        var lastLine: String? = nil

        func append(_ raw: String?) {
            guard let raw else { return }
            let cleaned = collapseWhitespace(raw)
            guard !cleaned.isEmpty else { return }
            // Drop duplicate adjacent lines.
            if cleaned == lastLine { return }
            lines.append(cleaned)
            lastLine = cleaned
            charCount += cleaned.count
        }

        func walk(_ element: AXUIElement, depth: Int) {
            if depth > Config.maxWalkDepth { return }
            if charCount >= Config.maxBodyCharsPerEntry { return }

            // Never read the value of a secure text field (password input). macOS
            // usually masks it, but not always — skip it outright rather than rely
            // on that. The label (title/description) is still safe to read.
            let isSecure = copyString(element, kAXSubroleAttribute) == "AXSecureTextField"
            if !isSecure {
                append(copyString(element, kAXValueAttribute))
                if charCount >= Config.maxBodyCharsPerEntry { return }
            }
            append(copyString(element, kAXTitleAttribute))
            append(copyString(element, kAXDescriptionAttribute))

            for child in copyChildren(element) {
                if charCount >= Config.maxBodyCharsPerEntry { return }
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func collapseWhitespace(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+",
                                               with: " ",
                                               options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Browser URL

    /// Browsers only: attempt the AX web-area `kAXURLAttribute`. If unavailable,
    /// returns nil — never falls back to AppleScript automation prompts.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
    ]

    static func browserURL(window: AXUIElement, bundleID: String?) -> String? {
        guard let bundleID, browserBundleIDs.contains(bundleID) else { return nil }
        guard let webArea = findWebArea(window, depth: 0) else { return nil }

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return (value as! CFURL as URL).absoluteString
        }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return (value as! CFString as String)
        }
        return nil
    }

    /// Find the first AXWebArea element in the subtree (shallow, depth-guarded).
    private static func findWebArea(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > Config.maxWalkDepth { return nil }
        if let role = copyString(element, kAXRoleAttribute), role == "AXWebArea" {
            return element
        }
        for child in copyChildren(element) {
            if let found = findWebArea(child, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Electron / Chromium

    /// Detect Electron via known bundle IDs, with a structural fallback: the app
    /// bundle contains a `* Helper (Renderer).app`.
    static func detectElectron(bundleID: String?, app: NSRunningApplication) -> Bool {
        if let bundleID, Config.electronBundleIDs.contains(bundleID) { return true }
        guard let bundleURL = app.bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: frameworks.path) else {
            return false
        }
        return entries.contains { $0.hasSuffix("Helper (Renderer).app") }
    }

    /// Force Chromium to build its a11y tree by setting the manual-accessibility
    /// flags on the app-level element. MUST be the main app PID.
    static func enableChromiumA11y(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        // Newer Electron honors AXManualAccessibility; older honors
        // AXEnhancedUserInterface. Setting both is idempotent and harmless.
        // AXManualAccessibility may return AttributeUnsupported — ignore it.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}
