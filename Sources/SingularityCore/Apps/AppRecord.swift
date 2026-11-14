import Foundation

/// A key the owner stored for an app: its name (`env.NAME` in the Worker), the one host it may
/// be sent to, and whether the app's code may read the real value. The value itself is never
/// here: it lives in the key store (`AppKeyStore`; the macOS keychain in a normal copy).
public struct AppKey: Codable, Hashable, Sendable {
    public var name: String
    public var host: String
    /// False (the default): the Worker gets a placeholder, and Singularity puts the real value
    /// into requests for `host`. True: the Worker gets the real value, for APIs that sign
    /// requests with the key.
    public var readable: Bool

    public init(name: String, host: String, readable: Bool = false) {
        self.name = name
        self.host = host
        self.readable = readable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        readable = try container.decodeIfPresent(Bool.self, forKey: .readable) ?? false
    }
}

/// What the owner allowed one app, kept in `space.json` under the app's path (`Space.apps`).
/// It is not in the app's folder on purpose: agents write that folder.
public struct AppRecord: Codable, Hashable, Sendable {
    /// Hosts the Worker may send requests to (lowercase, no port).
    public var hosts: [String]
    public var keys: [AppKey]

    public init(hosts: [String] = [], keys: [AppKey] = []) {
        self.hosts = hosts
        self.keys = keys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
        keys = (try? container.decodeIfPresent([AppKey].self, forKey: .keys)) ?? []
    }

    public var isEmpty: Bool { hosts.isEmpty && keys.isEmpty }
}
