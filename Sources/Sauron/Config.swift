import Foundation

enum Config {
    // Default Obsidian daily-notes folder, used only as a fallback. On first run
    // the welcome screen has the user choose their vault folder, and that choice
    // (persisted in Settings) overrides this. Files are written as YYYY-MM-DD.md.
    static let dailyNotesDir = "\(NSHomeDirectory())/Documents/Obsidian/daily"

    // Captures are written verbatim to a local staging log first, then rolled
    // up into ONE summarized, datestamped bullet in the Obsidian daily note.
    // A summary is produced when EITHER trigger fires, whichever comes first:

    //   • the staging log reaches this many lines, or
    static let summaryLineThreshold = 40

    //   • this much time elapses with anything buffered.
    static let summaryInterval: TimeInterval = 15 * 60   // 15 minutes

    // Optional safety poll of the focused window title (catches apps that
    // don't emit AX title-changed events). Set to 0 to disable.
    static let safetyPollInterval: TimeInterval = 60

    // Apps that must NEVER be captured — not even the window title.
    // Match on bundle identifier. Extend as needed. This is the first of several
    // layers; see SensitiveFilter for content-level redaction that catches
    // secrets in apps NOT on this list (e.g. a card number typed in a browser).
    static let blocklistBundleIDs: Set<String> = [
        // Password managers / keychains.
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "com.lastpass.LastPass",
        // Banking / finance desktop apps.
        "com.apple.wallet",          // Wallet (cards)
        // add more banking / sensitive apps here
    ]

    // Browser pages whose body text must NEVER be captured — banking, brokerages,
    // health portals, government. Matched as a case-insensitive SUBSTRING of the
    // URL host, so "chase.com" also blocks "secure.chase.com". The page's title
    // and host are still recorded (a breadcrumb), but no body text is read.
    static let sensitiveHostSubstrings: Set<String> = [
        // Banks / payments.
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citibank.com",
        "capitalone.com", "usbank.com", "pnc.com", "discover.com",
        "americanexpress.com", "paypal.com", "venmo.com", "wise.com",
        // Brokerages / crypto.
        "fidelity.com", "schwab.com", "vanguard.com", "etrade.com",
        "robinhood.com", "coinbase.com", "kraken.com", "binance.com",
        // Health / government.
        "myhealth", "mychart", "irs.gov", "ssa.gov", "login.gov",
        // Generic online-banking giveaways.
        "onlinebanking", "secure.bank",
    ]

    // Suspend ALL capture whenever macOS reports secure event input is active
    // (a password is being entered anywhere — the OS-level signal password
    // managers use to block keyloggers). App-agnostic and fails closed; catches
    // secrets in apps the blocklist doesn't know about. Leave ON.
    static let pauseDuringSecureInput = true

    // Capture the visible body text of the focused window, not just its title.
    // ON by default — this is what makes Sauron an actual content log (real
    // text from the window), not just a breadcrumb trail of app + title. See
    // "Reading a window" for the subtree walk.
    static let captureBodyText = true

    // Per-entry cap on captured body text, so a huge DOM can't bloat a note.
    static let maxBodyCharsPerEntry = 1500

    // Electron/Chromium apps need their a11y tree force-enabled before their
    // text is readable. Only these get flagged.
    static let electronBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",   // Slack
        "com.microsoft.VSCode",        // VS Code
        "com.hnc.Discord",             // Discord
        "md.obsidian",                 // Obsidian
        "notion.id",                   // Notion
        // extend as needed
    ]

    // Recursion depth guard for the AX subtree walk.
    static let maxWalkDepth = 60

    // Delay before re-walking an Electron app whose first walk came back empty
    // (Chromium materializes its a11y tree asynchronously after the flag is set).
    static let electronRetryDelay: TimeInterval = 0.25
}
