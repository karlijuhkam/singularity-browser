import Foundation

/// An HTTP request as it travels between the app and a Worker: the page's request on its way
/// in, or the Worker's own `fetch()` on its way out. Headers are pairs, not a dictionary,
/// because a name may repeat (`Set-Cookie`).
public struct AppHTTPRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [(String, String)]
    public var body: Data?

    public init(method: String, url: String, headers: [(String, String)] = [], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct AppHTTPResponse: Sendable {
    public var status: Int
    public var statusText: String
    public var headers: [(String, String)]
    public var body: Data
    /// For an outside request: the address that finally answered (after redirects).
    public var url: String?

    public init(status: Int, statusText: String = "", headers: [(String, String)] = [], body: Data = Data(), url: String? = nil) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
        self.url = url
    }

    /// A plain-text answer (errors the app itself reports for a Worker).
    public static func text(_ status: Int, _ message: String) -> AppHTTPResponse {
        AppHTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(message.utf8))
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

/// What the app sends a Worker's host script (`Resources/plugin-host/app-host.ts`), one JSON
/// object per line on its stdin. The field `t` names the message; bodies are base64.
enum AppWireOut {
    /// First line: the Worker's keys (real values or placeholders) and its two folders.
    case start(keys: [String: String], dataFolder: String, appFolder: String)
    case request(id: Int, AppHTTPRequest)
    case fetchResult(id: Int, Result<AppHTTPResponse, AppFetchRefusal>)
    /// Finish `ctx.waitUntil` work and exit.
    case stop

    /// One line, with its "\n". JSONSerialization never writes a raw newline inside a value.
    func line() -> Data {
        var object: [String: Any]
        switch self {
        case let .start(keys, dataFolder, appFolder):
            object = ["t": "start", "keys": keys, "dataFolder": dataFolder, "appFolder": appFolder]
        case let .request(id, request):
            object = ["t": "request", "id": id, "method": request.method, "url": request.url,
                      "headers": request.headers.map { [$0.0, $0.1] },
                      "body": request.body.map { $0.base64EncodedString() as Any } ?? NSNull()]
        case let .fetchResult(id, .success(response)):
            object = ["t": "fetchResult", "id": id, "status": response.status, "statusText": response.statusText,
                      "headers": response.headers.map { [$0.0, $0.1] },
                      "body": response.body.base64EncodedString(), "url": response.url ?? ""]
        case let .fetchResult(id, .failure(refusal)):
            object = ["t": "fetchResult", "id": id, "error": refusal.message]
        case .stop:
            object = ["t": "stop"]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

/// What a Worker's host script sends the app, one JSON object per line on its stdout.
enum AppWireIn: Sendable {
    /// The config was read, migrations applied and the Worker imported: requests may come.
    case ready
    /// The Worker can't start; the process exits after this.
    case failed(message: String)
    case response(id: Int, AppHTTPResponse)
    /// The Worker called `fetch()`.
    case fetch(id: Int, AppHTTPRequest)
    case log(level: String, text: String)
    /// The Worker read `env.NAME` and there is no such key.
    case envRead(name: String)

    /// Nil for a line that is not one of ours (the caller keeps it as a log line).
    static func decode(_ line: Data) -> AppWireIn? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = object["t"] as? String else { return nil }
        switch kind {
        case "ready":
            return .ready
        case "failed":
            return .failed(message: object["message"] as? String ?? "The Worker could not start.")
        case "response":
            guard let id = object["id"] as? Int, let status = object["status"] as? Int,
                  let body = decodeBody(object["body"]) else { return nil }
            return .response(id: id, AppHTTPResponse(status: status, headers: headers(object["headers"]), body: body ?? Data()))
        case "fetch":
            guard let id = object["id"] as? Int, let method = object["method"] as? String,
                  let url = object["url"] as? String, let body = decodeBody(object["body"]) else { return nil }
            return .fetch(id: id, AppHTTPRequest(method: method, url: url, headers: headers(object["headers"]), body: body))
        case "log":
            guard let text = object["text"] as? String else { return nil }
            return .log(level: object["level"] as? String == "error" ? "error" : "info", text: text)
        case "envRead":
            guard let name = object["name"] as? String else { return nil }
            return .envRead(name: name)
        default:
            return nil
        }
    }

    private static func headers(_ value: Any?) -> [(String, String)] {
        guard let pairs = value as? [[Any]] else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2, let name = pair[0] as? String, let value = pair[1] as? String else { return nil }
            return (name, value)
        }
    }

    /// base64 or null. The outer optional is "valid", the inner "there is a body".
    private static func decodeBody(_ value: Any?) -> Data?? {
        if value == nil || value is NSNull { return .some(nil) }
        guard let text = value as? String, let data = Data(base64Encoded: text) else { return nil }
        return .some(data)
    }
}
