import Foundation

/// A single point-in-time reading of the foreground window.
struct Capture {
    let timestamp: Date
    let app: String       // localizedName
    let title: String?
    let url: String?
    let body: String?     // visible text collected from the subtree (captureBodyText)

    /// Dedup key: app + title + url. Two captures with the same key are the
    /// same context and collapse to one entry.
    var key: String {
        "\(app)|\(title ?? "")|\(url ?? "")"
    }
}
