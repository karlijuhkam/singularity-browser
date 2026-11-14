import Foundation
import Testing
@testable import SingularityCore

@Suite struct AppHostRulesTests {
    @Test func httpsToAnyHostAndHttpOnlyToThisMac() {
        #expect(AppHostRules.target(of: "https://api.example.com/v1/x?a=1") == .success("api.example.com"))
        #expect(AppHostRules.target(of: "https://API.Example.COM:8443/") == .success("api.example.com"))
        #expect(AppHostRules.target(of: "http://localhost:3000/x") == .success("localhost"))
        #expect(AppHostRules.target(of: "http://127.0.0.1:8080/") == .success("127.0.0.1"))
        #expect(AppHostRules.target(of: "http://[::1]:8080/") == .success("::1"))
        #expect(AppHostRules.target(of: "https://example.com./") == .success("example.com"))
    }

    @Test func refusesPlainHttpElsewhereOtherSchemesAndCredentials() {
        func message(_ url: String) -> String? {
            if case .failure(let refusal) = AppHostRules.target(of: url) { return refusal.message }
            return nil
        }
        #expect(message("http://example.com/")?.contains("https") == true)
        #expect(message("http://example.com/")?.contains("example.com") == true)
        #expect(message("ftp://example.com/") != nil)
        #expect(message("file:///etc/passwd") != nil)
        #expect(message("https://user:pw@example.com/") != nil)
        #expect(message("https://user@example.com/") != nil)
        #expect(message("not an address") != nil)
        #expect(message("/relative") != nil)
        // The password never appears in the message.
        #expect(message("https://user:hunter2@example.com/")?.contains("hunter2") == false)
    }

    /// A host that could not be listed (and so never allowed) is refused before anyone is asked.
    @Test func hostsThatCannotBeListedAreRefused() {
        if case .success = AppHostRules.target(of: "https://[2001:db8::1]/x") { Issue.record("an IPv6 literal was taken") }
        #expect(AppHostRules.target(of: "https://my_api.example.com/") == .success("my_api.example.com"))
        // Whatever `target` returns can be listed.
        for url in ["https://api.example.com/", "http://localhost:1/", "http://[::1]:2/", "https://EXAMPLE.com./"] {
            if case .success(let host) = AppHostRules.target(of: url) { #expect(AppHostRules.isValidHost(host), "\(host)") }
        }
    }

    @Test func aHostTypedByHandIsAHostOnly() {
        for good in ["api.example.com", "localhost", "127.0.0.1", "::1", "a-b.example", "my_api.example.com"] {
            #expect(AppHostRules.isValidHost(good), "\(good)")
        }
        for bad in ["", "https://example.com", "example.com/x", "example.com:443", "Example.com", "*.example.com",
                    "a b", ".example.com", "example.com.", "a..b", "-a.com", "fe80::1"] {
            #expect(!AppHostRules.isValidHost(bad), "\(bad)")
        }
    }
}

@Suite struct AppHostGateTests {
    @Test func asksOnceAndLaterRequestsShareTheQuestion() {
        var gate = AppHostGate(allowed: ["ok.example"])
        #expect(gate.decide("ok.example") == .allow)
        #expect(gate.decide("new.example") == .ask)
        #expect(gate.decide("new.example") == .joinWaiting)
        #expect(gate.decide("other.example") == .ask)
        gate.answered("new.example", allowed: true)
        #expect(gate.decide("new.example") == .allow)
        #expect(gate.deniedThisRun.isEmpty)
    }

    @Test func aDeniedHostStaysQuietForThisRun() {
        var gate = AppHostGate(allowed: [])
        #expect(gate.decide("no.example") == .ask)
        gate.answered("no.example", allowed: false)
        #expect(gate.decide("no.example") == .refuse)
        #expect(gate.decide("no.example") == .refuse)
        #expect(gate.deniedThisRun == ["no.example"])
        // A new run (a new gate) asks again.
        var next = AppHostGate(allowed: [])
        #expect(next.decide("no.example") == .ask)
    }

    @Test func thePanelCanAllowADeniedHost() {
        var gate = AppHostGate(allowed: [])
        _ = gate.decide("no.example")
        gate.answered("no.example", allowed: false)
        gate.setAllowed(["no.example"])
        #expect(gate.decide("no.example") == .allow)
        #expect(gate.deniedThisRun.isEmpty)
        // And take a host away again.
        gate.setAllowed([])
        #expect(gate.decide("no.example") == .ask)
    }

    @Test func aQuestionThatCouldNotBeAskedIsAskedAgain() {
        var gate = AppHostGate(allowed: [])
        #expect(gate.decide("x.example") == .ask)
        gate.notAsked("x.example")
        #expect(gate.deniedThisRun.isEmpty)
        #expect(gate.decide("x.example") == .ask)
    }

    @Test func aLateNoDoesNotUndoAnAllowFromThePanel() {
        var gate = AppHostGate(allowed: [])
        #expect(gate.decide("x.example") == .ask)
        gate.setAllowed(["x.example"])
        gate.answered("x.example", allowed: false)   // the question timed out afterwards
        #expect(gate.decide("x.example") == .allow)
    }
}

@Suite struct AppKeySubstitutionTests {
    let key = AppKeyMaterial(name: "API_KEY", host: "api.example.com", value: "s3cr3t-value",
                             placeholder: "sgkey_00000000000000000000000000000001", readable: false)

    @Test func placeholdersAreUniqueAndPlain() {
        let one = AppKeySubstitution.makePlaceholder(), two = AppKeySubstitution.makePlaceholder()
        #expect(one != two)
        #expect(one.hasPrefix("sgkey_"))
        #expect(one.count == 38)
        #expect(one.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) })
    }

    @Test func theWorkerGetsThePlaceholderUnlessTheKeyIsReadable() {
        var readable = key
        readable.name = "SIGNING_KEY"
        readable.readable = true
        let environment = AppKeySubstitution.environment([key, readable])
        #expect(environment == ["API_KEY": key.placeholder, "SIGNING_KEY": "s3cr3t-value"])
    }

    @Test func theValueGoesOnlyToTheKeysHost() {
        let headers = [("Authorization", "Bearer \(key.placeholder)"), ("Accept", "*/*")]
        let body = Data(#"{"token":"\#(key.placeholder)"}"#.utf8)
        let sent = AppKeySubstitution.outgoing(url: "https://api.example.com/x?key=\(key.placeholder)", headers: headers,
                                               body: body, host: "api.example.com", keys: [key])
        #expect(sent.url == "https://api.example.com/x?key=s3cr3t-value")
        #expect(sent.headers[0].1 == "Bearer s3cr3t-value")
        #expect(sent.headers[1].1 == "*/*")
        #expect(String(decoding: sent.body!, as: UTF8.self) == #"{"token":"s3cr3t-value"}"#)

        let elsewhere = AppKeySubstitution.outgoing(url: "https://evil.example/x?key=\(key.placeholder)", headers: headers,
                                                    body: body, host: "evil.example", keys: [key])
        #expect(elsewhere.url.contains(key.placeholder))
        #expect(elsewhere.headers[0].1 == "Bearer \(key.placeholder)")
        #expect(elsewhere.body == body)
        // A subdomain is another host.
        let sub = AppKeySubstitution.outgoing(url: "https://x.api.example.com/", headers: headers, body: nil,
                                              host: "x.api.example.com", keys: [key])
        #expect(sub.headers[0].1 == "Bearer \(key.placeholder)")
    }

    @Test func anyCharactersInAValueSurvive() {
        var odd = key
        odd.value = #"a$&\1"b{c}.*+ ü/=?"#
        let sent = AppKeySubstitution.outgoing(url: "https://api.example.com/?k=\(odd.placeholder)",
                                               headers: [("X-Key", odd.placeholder)],
                                               body: Data("k=\(odd.placeholder)&again=\(odd.placeholder)".utf8),
                                               host: "api.example.com", keys: [odd])
        #expect(sent.headers[0].1 == odd.value)
        #expect(String(decoding: sent.body!, as: UTF8.self) == "k=\(odd.value)&again=\(odd.value)")
        // In the address the value is percent-encoded, so it stays one query value.
        #expect(URLComponents(string: sent.url)?.queryItems?.first?.value == odd.value)
        let back = AppKeySubstitution.incoming(headers: [("X-Echo", odd.value)], body: sent.body, keys: [odd])
        #expect(back.headers[0].1 == odd.placeholder)
        #expect(String(decoding: back.body!, as: UTF8.self) == "k=\(odd.placeholder)&again=\(odd.placeholder)")
    }

    /// A body is changed as bytes: whatever is around the key stays exactly as it was, also
    /// when the body is not text.
    @Test func bodiesAreChangedAsBytes() {
        let odd = Data([0xFF, 0xFE, 0x00, 0x80])
        let sent = AppKeySubstitution.outgoing(url: "https://api.example.com/", headers: [],
                                               body: odd + Data(key.placeholder.utf8) + odd,
                                               host: "api.example.com", keys: [key])
        #expect(sent.body == odd + Data("s3cr3t-value".utf8) + odd)
        // Nothing to replace: the same bytes.
        let plain = Data("hello".utf8)
        #expect(AppKeySubstitution.incoming(headers: [], body: plain, keys: [key]).body == plain)
        #expect(AppKeySubstitution.incoming(headers: [], body: nil, keys: [key]).body == nil)
    }

    /// An answer that is not valid UTF-8 (a Latin-1 page, one bad byte) still loses the key.
    @Test func anEchoInABodyThatIsNotUTF8IsStillHidden() {
        let latin1 = Data([0x6B, 0x65, 0x79, 0x3A, 0x20, 0xE4, 0x20]) + Data("s3cr3t-value".utf8) + Data([0xFC])
        let back = AppKeySubstitution.incoming(headers: [], body: latin1, keys: [key])
        #expect(back.body?.range(of: Data("s3cr3t-value".utf8)) == nil)
        #expect(back.body?.range(of: Data(key.placeholder.utf8)) != nil)
        #expect(back.body?.prefix(7) == latin1.prefix(7))
        #expect(back.body?.last == 0xFC)
    }

    /// The value is written the way its place needs it, so the request stays well-formed.
    @Test func theValueIsEscapedForJSONAndFormBodies() throws {
        var odd = key
        odd.value = #"a"b\c&d=e+f %/ü"#
        let json = AppKeySubstitution.outgoing(
            url: "https://api.example.com/", headers: [("Content-Type", "application/json; charset=utf-8")],
            body: Data(#"{"token":"\#(odd.placeholder)","n":1}"#.utf8), host: "api.example.com", keys: [odd])
        let parsed = try #require(try JSONSerialization.jsonObject(with: json.body!) as? [String: Any])
        #expect(parsed["token"] as? String == odd.value)
        #expect(parsed["n"] as? Int == 1)

        let form = AppKeySubstitution.outgoing(
            url: "https://api.example.com/", headers: [("content-type", "application/x-www-form-urlencoded")],
            body: Data("key=\(odd.placeholder)&other=1".utf8), host: "api.example.com", keys: [odd])
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: form.body!, as: UTF8.self)
        #expect(components.queryItems?.first { $0.name == "key" }?.value == odd.value)
        #expect(components.queryItems?.first { $0.name == "other" }?.value == "1")

        // And an answer that echoes it in either form comes back with the placeholder.
        for echoed in [json.body!, form.body!] {
            let back = AppKeySubstitution.incoming(headers: [], body: echoed, keys: [odd])
            #expect(String(decoding: back.body!, as: UTF8.self).contains(odd.placeholder))
            #expect(!String(decoding: back.body!, as: UTF8.self).contains("a\\\"b"))
        }
    }

    /// An address the outside wrote (a redirect) may repeat the key: it is hidden before the
    /// Worker can read it as `response.url`.
    @Test func aValueInAnAddressFromOutsideIsHidden() {
        var odd = key
        odd.value = "s3cr3t value&more"
        let raw = AppKeySubstitution.scrubURL("https://api.example.com/v1/?key=s3cr3t-value&x=1", keys: [key])
        #expect(raw == "https://api.example.com/v1/?key=\(key.placeholder)&x=1")
        let encoded = AppKeySubstitution.scrubURL("https://api.example.com/?key=s3cr3t%20value%26more", keys: [odd])
        #expect(encoded == "https://api.example.com/?key=\(odd.placeholder)")
        var readable = key
        readable.readable = true
        #expect(AppKeySubstitution.scrubURL("https://x/?k=s3cr3t-value", keys: [readable]) == "https://x/?k=s3cr3t-value")
    }

    /// A key of several lines (a PEM file) is printed line by line: each line is hidden.
    @Test func eachLineOfALongValueIsHiddenInTheLog() {
        var pem = key
        pem.name = "PEM"
        pem.value = "-----BEGIN KEY-----\nMIIBVgIBADANBgkqhkiG\n9w0BAQEFAASCAUAwggE8\n-----END KEY-----"
        #expect(AppKeySubstitution.scrubLog("line: MIIBVgIBADANBgkqhkiG", keys: [pem]) == "line: [key PEM]")
        #expect(AppKeySubstitution.scrubLog("9w0BAQEFAASCAUAwggE8 end", keys: [pem]) == "[key PEM] end")
        #expect(AppKeySubstitution.scrubLog(#"json "s3cr3t-value" and %"#, keys: [key]) == #"json "[key API_KEY]" and %"#)
    }

    @Test func anEchoedValueComesBackAsThePlaceholderUnlessReadable() {
        let body = Data("your key is s3cr3t-value".utf8)
        let hidden = AppKeySubstitution.incoming(headers: [], body: body, keys: [key])
        #expect(String(decoding: hidden.body!, as: UTF8.self) == "your key is \(key.placeholder)")
        var readable = key
        readable.readable = true
        #expect(AppKeySubstitution.incoming(headers: [], body: body, keys: [readable]).body == body)
        // A readable key is never put into a request by us either: the code does that itself.
        let sent = AppKeySubstitution.outgoing(url: "https://api.example.com/", headers: [("X", readable.placeholder)],
                                               body: nil, host: "api.example.com", keys: [readable])
        #expect(sent.headers[0].1 == readable.placeholder)
    }

    @Test func theLogNeverHoldsAValueOrAPlaceholder() {
        var readable = key
        readable.name = "SIGNING_KEY"
        readable.value = "sign-me"
        readable.placeholder = "sgkey_00000000000000000000000000000002"
        readable.readable = true
        let line = "auth s3cr3t-value / \(key.placeholder) / sign-me done"
        #expect(AppKeySubstitution.scrubLog(line, keys: [key, readable]) == "auth [key API_KEY] / [key API_KEY] / [key SIGNING_KEY] done")
        #expect(AppKeySubstitution.scrubLog("nothing here", keys: [key]) == "nothing here")
    }

    @Test func aValueInsideAnotherValueIsReplacedWhole() {
        var short = key
        short.name = "SHORT"
        short.value = "abc"
        var long = key
        long.name = "LONG"
        long.value = "abcdef"
        #expect(AppKeySubstitution.scrubLog("x abcdef y abc", keys: [short, long]) == "x [key LONG] y [key SHORT]")
    }

    @Test func keyNamesAreIdentifiers() {
        for good in ["API_KEY", "_x", "a1", "Merit"] { #expect(AppKeySubstitution.isValidName(good), "\(good)") }
        for bad in ["", "1A", "A-B", "A B", "A.B", "ü", String(repeating: "A", count: 65)] {
            #expect(!AppKeySubstitution.isValidName(bad), "\(bad)")
        }
    }
}

@Suite struct AppKeyStoreTests {
    let space = UUID(), other = UUID()

    func check(_ store: AppKeyStore) throws {
        try store.set("one", space: space, app: "firma", name: "A")
        try store.set("two", space: space, app: "firma", name: "B")
        try store.set("three", space: space, app: "firma2", name: "A")
        try store.set("four", space: other, app: "firma", name: "A")
        #expect(store.value(space: space, app: "firma", name: "A") == "one")
        #expect(store.value(space: space, app: "firma", name: "missing") == nil)
        try store.set("uno", space: space, app: "firma", name: "A")
        #expect(store.value(space: space, app: "firma", name: "A") == "uno")

        store.delete(space: space, app: "firma", name: "B")
        #expect(store.value(space: space, app: "firma", name: "B") == nil)

        // An app whose name starts like another's keeps its keys.
        store.deleteAll(space: space, app: "firma")
        #expect(store.value(space: space, app: "firma", name: "A") == nil)
        #expect(store.value(space: space, app: "firma2", name: "A") == "three")
        #expect(store.value(space: other, app: "firma", name: "A") == "four")

        store.deleteAll(space: space, app: nil)
        #expect(store.value(space: space, app: "firma2", name: "A") == nil)
        #expect(store.value(space: other, app: "firma", name: "A") == "four")
    }

    @Test func memoryStore() throws {
        try check(MemoryAppKeyStore())
    }

    @Test func fileStoreIsPrivateAndSurvivesAReload() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "app-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "app-keys.json")
        try check(FileAppKeyStore(file: file))

        let store = FileAppKeyStore(file: file)
        try store.set("kept", space: space, app: "firma", name: "A")
        #expect(FileAppKeyStore(file: file).value(space: space, app: "firma", name: "A") == "kept")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // No temporary files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["app-keys.json"])
    }

    @Test func anUnreadableFileReadsAsNoKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "app-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "app-keys.json")
        try Data("not json".utf8).write(to: file)
        #expect(FileAppKeyStore(file: file).value(space: space, app: "firma", name: "A") == nil)
    }
}
