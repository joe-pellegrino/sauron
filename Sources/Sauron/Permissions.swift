import ApplicationServices
import AppKit

/// Accessibility trust check + prompt. The app should function with ONLY the
/// Accessibility permission — no other TCC prompts should ever appear.
enum Permissions {

    /// Is the process currently trusted for Accessibility?
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Surface the system Accessibility prompt (the one-time TCC dialog).
    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings directly to Privacy & Security › Accessibility. Used
    /// when the prompt alone isn't enough — e.g. a stale entry from a previous
    /// build needs to be toggled off/on, or the user dismissed the dialog.
    static func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
