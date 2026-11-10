import Foundation

/// The page shown in a tab when a site can't be loaded (offline, unknown host, bad certificate…).
/// Without it WKWebView just stays blank.
public enum LoadErrorPage {
    /// Whether a failed navigation deserves the error page. Some "failures" are normal:
    /// the user or the app cancelled the load, or the response became a download.
    public static func shouldShow(domain: String, code: Int) -> Bool {
        if domain == NSURLErrorDomain, code == NSURLErrorCancelled { return false }
        // WebKit's own codes: 102 = "frame load interrupted" (a navigation that turned into a
        // download or was cancelled by policy), 204 = "plug-in handled load" (media opened directly).
        if domain == "WebKitErrorDomain", code == 102 || code == 204 { return false }
        return true
    }

    /// A self-contained page: no scripts, nothing loaded from anywhere. `url` and `message` come
    /// from the failed request and the system, so both are escaped.
    public static func html(url: String, message: String) -> String {
        let safeURL = escape(url)
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <title>Can’t open this page</title>
        <style>
          body { font: 14px -apple-system, sans-serif; margin: 18vh auto 0; max-width: 520px; padding: 0 24px; color: CanvasText; background: Canvas; }
          h1 { font-size: 22px; font-weight: 600; margin: 0 0 12px; }
          p { line-height: 1.5; margin: 0 0 12px; }
          .url { color: GrayText; word-break: break-all; }
          a.retry { display: inline-block; margin-top: 8px; padding: 6px 14px; border-radius: 6px; background: AccentColor; color: AccentColorText; text-decoration: none; }
        </style></head>
        <body>
          <h1>Can’t open this page</h1>
          <p>\(escape(message))</p>
          <p class="url">\(safeURL)</p>
          <a class="retry" href="\(safeURL)">Try Again</a>
        </body></html>
        """
    }

    /// HTML-escapes text for element content and double-quoted attributes.
    public static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}

/// Page zoom steps for ⌘+ / ⌘−, the same ladder other browsers use.
public enum PageZoom {
    public static let steps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// The next step above (`larger`) or below the current zoom; stays at the ends.
    public static func next(from current: Double, larger: Bool) -> Double {
        if larger {
            return steps.first { $0 > current + 0.001 } ?? steps[steps.count - 1]
        }
        return steps.last { $0 < current - 0.001 } ?? steps[0]
    }
}
