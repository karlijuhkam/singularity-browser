import Foundation
import SingularityCore

/// Makes a Worker's outside request for it. The Worker's sandbox has no network; its `fetch()`
/// arrives here (through `AppCenter`, after the host was allowed) and is made with `URLSession`.
///
/// Three things happen here that the Worker's code can't do or undo:
/// - a key's placeholder becomes the real value, only in a request for that key's own host;
/// - a redirect is followed only to a host the owner allowed, and the request is built again
///   from the Worker's original one for each hop, so a key never follows a redirect elsewhere;
/// - a real key value in the answer becomes the placeholder again.
enum AppOutbound {
    static let maxRedirects = 5
    static let timeout: TimeInterval = 30
    static let maxBodyBytes = 8 << 20

    /// No cookies, no cache, nothing on disk; and never a redirect followed by itself
    /// (`RedirectStopper`): we follow them ourselves, one checked hop at a time.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: configuration, delegate: RedirectStopper(), delegateQueue: nil)
    }()

    /// - Parameters:
    ///   - request: as the Worker wrote it (placeholders, not values).
    ///   - isAllowed: whether the owner allowed a host for this app, asked for every redirect.
    static func perform(_ request: AppHTTPRequest, keys: [AppKeyMaterial],
                        isAllowed: @Sendable (String) async -> Bool) async -> Result<AppHTTPResponse, AppFetchRefusal> {
        var current = request
        for _ in 0...maxRedirects {
            let host: String
            switch AppHostRules.target(of: current.url) {
            case .success(let target): host = target
            case .failure(let refusal): return .failure(refusal)
            }
            guard await isAllowed(host) else {
                return .failure(AppFetchRefusal("The request was redirected to \(host), which is not allowed for this app."))
            }

            let sent = AppKeySubstitution.outgoing(url: current.url, headers: current.headers, body: current.body,
                                                   host: host, keys: keys)
            guard let url = URL(string: sent.url) else {
                return .failure(AppFetchRefusal("Not an address an app can fetch."))
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = current.method
            urlRequest.httpBody = sent.body
            for (name, value) in sent.headers where !skippedRequestHeaders.contains(name.lowercased()) {
                urlRequest.addValue(value, forHTTPHeaderField: name)
            }

            let response: HTTPURLResponse, body: Data
            do {
                (response, body) = try await load(urlRequest)
            } catch let refusal as AppFetchRefusal {
                return .failure(refusal)
            } catch {
                // The error's text only: its userInfo holds the address, which may hold a key.
                let text = AppKeySubstitution.scrubLog((error as NSError).localizedDescription, keys: keys)
                return .failure(AppFetchRefusal("The request to \(host) failed: \(text)"))
            }

            if [301, 302, 303, 307, 308].contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: URL(string: current.url))?.absoluteString {
                // Where the Worker's own request goes next: still with placeholders, so the key
                // is put in again only if the new host is the key's.
                current.url = next
                if response.statusCode == 303 || ((response.statusCode == 301 || response.statusCode == 302) && current.method == "POST") {
                    current.method = "GET"
                    current.body = nil
                    current.headers.removeAll { ["content-type", "content-length"].contains($0.0.lowercased()) }
                }
                continue
            }

            var headers: [(String, String)] = []
            for (name, value) in response.allHeaderFields {
                guard let name = name as? String, let value = value as? String,
                      !skippedResponseHeaders.contains(name.lowercased()) else { continue }
                headers.append((name, value))
            }
            let received = AppKeySubstitution.incoming(headers: headers, body: body, keys: keys)
            return .success(AppHTTPResponse(status: response.statusCode, headers: received.headers,
                                            body: received.body ?? Data(), url: current.url))
        }
        return .failure(AppFetchRefusal("Too many redirects (more than \(maxRedirects))."))
    }

    /// The answer's head and its whole body, refused once it passes the size limit.
    private static func load(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppFetchRefusal("The answer was not an HTTP response.")
        }
        var body = Data()
        if http.expectedContentLength > 0 { body.reserveCapacity(min(Int(http.expectedContentLength), maxBodyBytes)) }
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxBodyBytes {
                bytes.task.cancel()
                throw AppFetchRefusal("The answer is larger than the 8 MB an app can fetch.")
            }
        }
        return (http, body)
    }

    /// URLSession sets these itself; a Worker's value would be wrong or refused.
    private static let skippedRequestHeaders: Set<String> = ["host", "content-length", "connection", "accept-encoding"]
    /// URLSession already decoded the body, so its encoding and length no longer describe it.
    private static let skippedResponseHeaders: Set<String> = ["content-encoding", "content-length", "transfer-encoding"]

    /// Tells URLSession not to follow a redirect: the 3xx answer comes back to `perform`.
    private final class RedirectStopper: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
