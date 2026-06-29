import Foundation

/// User-adjustable settings, persisted to `UserDefaults` (on-device only — no
/// network). Currently just the Obsidian daily-notes folder; `Config` holds the
/// built-in default used until the user picks their own.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private static let dailyNotesDirKey = "dailyNotesDir"
    private static let didCompleteWelcomeKey = "didCompleteWelcome"

    /// Obsidian daily-notes folder. `YYYY-MM-DD.md` files are written here.
    /// Falls back to `Config.dailyNotesDir` until the user sets one.
    @Published var dailyNotesDir: String {
        didSet { defaults.set(dailyNotesDir, forKey: Self.dailyNotesDirKey) }
    }

    /// True once the user has been through the first-run welcome screen. Until
    /// then, launch presents the welcome window so they can point Sauron at
    /// their vault and grant Accessibility before capture begins.
    @Published var didCompleteWelcome: Bool {
        didSet { defaults.set(didCompleteWelcome, forKey: Self.didCompleteWelcomeKey) }
    }

    /// Whether the user has ever explicitly chosen a daily-notes folder (as
    /// opposed to inheriting the built-in `Config` default). Drives the welcome
    /// screen's "you still need to pick a folder" hint.
    var hasChosenFolder: Bool {
        defaults.string(forKey: Self.dailyNotesDirKey) != nil
    }

    private init() {
        dailyNotesDir = defaults.string(forKey: Self.dailyNotesDirKey) ?? Config.dailyNotesDir
        didCompleteWelcome = defaults.bool(forKey: Self.didCompleteWelcomeKey)
    }
}
