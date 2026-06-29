# Sauron

A tiny, quiet macOS menu-bar app that watches the foreground window via the
Accessibility API, stages the captured text locally, and periodically rolls it
up into a single **on-device-summarized** bullet in your Obsidian daily note.

It is a deliberate, minimal alternative to OCR/screen-recording activity loggers:
it reads UI text directly from the Accessibility tree (near-idle when you aren't
switching context) and never captures the screen, audio, or video.

> **Zero network.** Sauron never opens a socket. All data stays on-device and
> goes only to your local Obsidian vault. Summarization uses Apple's on-device
> foundation model — there is no cloud LLM, no telemetry, no sync.

## What it does

1. **Capture** the foreground app, window title, visible body text, and (for
   browsers) the URL via the Accessibility API — event-driven, no busy polling.
2. **Stage** each capture to a local log so nothing is lost to a crash.
3. **Summarize** the pending chunk with Apple's on-device model when a trigger
   fires (the log fills up, or an interval elapses).
4. **Append** one `- HH:mm — <summary>` bullet to today's Obsidian daily note.

## Requirements

- **macOS 26 or later, on Apple Silicon.** The on-device `FoundationModels`
  summarizer requires it. (With Apple Intelligence off, Sauron still runs and
  writes a deterministic fallback bullet instead of a model summary.)
- **Xcode 26 or later** to build it.
- **Accessibility permission** — the only permission Sauron ever asks for. It
  never triggers the Screen Recording prompt or any other system dialog.

## Getting started

1. Open **`Sauron.xcodeproj`** in Xcode.
2. (First time only) Select the **Sauron** target → **Signing & Capabilities**,
   check **Automatically manage signing** (the project ships with manual, ad-hoc
   signing, so this is off by default), and choose your team. Any free Apple ID
   works. A real signing identity gives the build a stable code identity so macOS
   remembers your Accessibility grant across rebuilds — with ad-hoc signing you'd
   have to re-grant it after every build.
3. Select the **Sauron** scheme and press **Run** (⌘R).
4. On first launch a **welcome screen** lets you choose your Obsidian daily-notes
   folder and grant **Accessibility** access. Grant it, and Sauron starts logging
   from the menu bar — the `eye` icon (it dims to `eye.slash` when paused).

That's it. From the menu-bar icon you can pause/resume, flush the current chunk,
open today's note, change the Obsidian folder, and toggle launch-at-login.

> If macOS doesn't pick up an Accessibility grant after a rebuild, remove Sauron
> from **System Settings → Privacy & Security → Accessibility** and add it again
> (the welcome screen has an "Open Settings…" shortcut). Stable signing in step 2
> prevents this.

## Privacy & security

Sauron reads on-screen text broadly, so it is built to *not* log secrets. Defense
in depth, with the strongest layers being app-agnostic and fail-closed:

- **Secure Event Input pause** — captures nothing while any app has secure input
  active (a password is being entered anywhere).
- **App blocklist** — password managers, Keychain, Wallet are never read.
- **Sensitive-host gate** — banking/brokerage/health/gov pages aren't read.
- **Secure-field skip** — password (`AXSecureTextField`) values are never read.
- **Content redaction** — card numbers (Luhn-checked), SSNs, account/routing
  numbers, secrets, API keys, JWTs, and tokens are masked at capture **and** at
  the disk-write boundary.
- **File hardening** — the staging log is `0600`, its directory `0700`.
- **Semantic summarizer guard** — the on-device model is instructed to describe
  activity, never reproduce sensitive values.

No single layer is sufficient and nothing is "absolutely secure"; see
[`SECURITY.md`](SECURITY.md) for the full threat model and known limitations.

## Configuration

Defaults live at the top of [`Sources/Sauron/Config.swift`](Sources/Sauron/Config.swift)
— summary triggers, the app blocklist, sensitive-host list, body-text cap, and
the Electron app list. The Obsidian folder is chosen in-app (welcome screen or
the menu) and persisted; `Config.dailyNotesDir` is only a fallback.

## Contributing

The redaction layer has a regression test suite. Run it from the command line:

```sh
swift test
```

A failing `mustNotLeak` assertion means a change is leaking secrets — fix the
filter, not the test. The project also builds with SwiftPM (`swift build`), which
globs `Sources/` automatically; the Xcode project lists files explicitly, so
**a new `.swift` file must be added to both.**

## License

[MIT](LICENSE).
