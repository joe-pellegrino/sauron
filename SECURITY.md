# Security model

Sauron reads on-screen text via the Accessibility API, so it is designed from
the ground up to *not* log secrets and to *never* send data off the device.
This document is the threat model; please read it before trusting the tool with
your activity.

## Core guarantees

- **Zero network.** The app never opens a socket. There is no networking code in
  the sources, no cloud LLM, no telemetry, no sync, no auto-update ping.
  Summarization runs entirely on Apple's on-device `FoundationModels`.
- **Accessibility permission only.** Sauron never triggers Screen Recording or
  any other TCC prompt. No screenshots, OCR, audio, or video.
- **Local-only storage.** Captures stage to `~/Library/Application Support/Sauron/pending.log`
  (a transient buffer, cleared after each summary) and summaries go only to your
  local Obsidian vault.

## Sensitive-data defense in depth

No single check is sufficient and nothing here is "absolutely secure." Seven
independent layers each catch what the others miss; most run at capture time and
again at the disk-write boundary, so secrets never reach `pending.log`. The
strongest layers are app-agnostic and fail closed.

| Layer | Mechanism |
|-------|-----------|
| **Secure Event Input pause** | Captures nothing while any app has secure input active (a password being entered anywhere). OS-level, app-agnostic, fails closed — the strongest single check. |
| **App blocklist** | Password managers, Keychain, Wallet are never read. Weakest layer (a denylist — fails open for unlisted apps), so it is a backstop only. |
| **Sensitive-host gate** | For browsers, banking/brokerage/health/government pages have their body text skipped (host breadcrumb still recorded). |
| **Secure-field skip** | The Accessibility walk never reads the value of an `AXSecureTextField` (password inputs). |
| **Content redaction** | Masks card numbers (Luhn-validated), SSNs, IBANs, 12+ digit account/routing numbers, `password:`/`AWS_SECRET=`/`token=` pairs, AWS keys, prefixed tokens (`ghp_`, `xoxb-`, `sk_…`), JWTs, PEM private keys, and high-entropy tokens. Applied at capture **and** at the single point where bytes hit disk. The same technique as enterprise DLP. |
| **File hardening** | `pending.log` is `0600`, its directory `0700`. |
| **Semantic summarizer guard** | The on-device model is instructed to summarize *activity*, never reproduce sensitive *values*, and to treat `[redacted-…]` tokens as already-masked. The only layer that catches contextual secrets (door codes, salary, security-question answers) a regex cannot. |

The redaction layer is covered by a regression suite — run `swift test`. A
failing `mustNotLeak` assertion means a change is leaking secrets.

## Known limitations (be aware)

- **Redaction is pattern-based.** An unlabeled password that is an ordinary word
  (e.g. `swordfish`) with no nearby `password:` key is not caught — the
  app/host/secure-input layers are the net there.
- **Some base64 secrets slip the high-entropy rule.** A bare secret containing
  `/` or `+` with no env-var label can be missed; those characters are excluded
  from the token rule on purpose so it doesn't shred file paths.
- **No private/incognito detection.** Private browser windows are not
  auto-excluded (unreliable to detect via Accessibility).
- **Default posture is broad capture.** Body-text capture is on by default (the
  whole point of the tool). If you want maximum privacy over coverage, narrow
  the capture surface via the blocklist / sensitive-host list, or fork the
  sensitive-host gate into an app allowlist.

## Reporting a vulnerability

Please open an issue describing the problem (omit any real secret values). If
you have a redaction bypass, a reproducing string plus the expected mask is the
most useful report — and ideally a failing test case for
`Tests/SauronTests/SensitiveFilterTests.swift`.
