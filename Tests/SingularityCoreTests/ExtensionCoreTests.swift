import CryptoKit
import Foundation
import Security
import Testing
@testable import SingularityCore

/// Builds `.crx` files for tests, signed with a throwaway RSA key.
enum CRXFixture {
    static func makeKey() -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    }

    /// DER SubjectPublicKeyInfo for an RSA key (what Chrome puts in the header).
    static func spki(_ key: SecKey) -> Data {
        let pkcs1 = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = der(0x03, [0x00] + [UInt8](pkcs1))
        return Data(der(0x30, algorithm + bitString))
    }

    static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var length: [UInt8]
        if content.count < 128 { length = [UInt8(content.count)] } else {
            var n = content.count, bytes: [UInt8] = []
            while n > 0 { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
            length = [0x80 | UInt8(bytes.count)] + bytes
        }
        return [tag] + length + content
    }

    static func varint(_ value: Int) -> [UInt8] {
        var v = UInt64(value), out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7f); v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(number << 3 | 2) + varint(bytes.count) + bytes
    }

    /// A CRX3 file around `zip`. `claimedID` replaces the id in the signed header (to fake one).
    static func crx(zip: Data, key: SecKey, claimedID: Data? = nil, tamper: Bool = false) -> (data: Data, id: String) {
        let publicKey = spki(key)
        let crxID = claimedID ?? Data(SHA256.hash(data: publicKey).prefix(16))
        let signedHeader = field(1, [UInt8](crxID))
        var message = Data("CRX3 SignedData".utf8) + [0]
        var length = UInt32(signedHeader.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(contentsOf: signedHeader)
        message.append(zip)
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
        let proof = field(1, [UInt8](publicKey)) + field(2, [UInt8](signature))
        let header = field(2, proof) + field(10000, signedHeader)
        var data = Data("Cr24".utf8)
        var version = UInt32(3).littleEndian, headerLength = UInt32(header.count).littleEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &headerLength) { data.append(contentsOf: $0) }
        data.append(contentsOf: header)
        data.append(tamper ? zip + Data([0x00]) : zip)
        return (data, ChromeWebStore.idFromHashPrefix(crxID))
    }
}

@Suite struct ChromeWebStoreTests {
    @Test func detailPagesGiveTheID() {
        let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/detail/dark-reader/\(id)")) == id)
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/detail/\(id)")) == id)
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/detail/x/\(id)?hl=et#reviews")) == id)
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/detail/x/\(id)/reviews")) == nil)
        #expect(ChromeWebStore.extensionID(from: URL(string: "http://chromewebstore.google.com/detail/x/\(id)")) == nil)
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://evil.example/detail/x/\(id)")) == nil)
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com.evil.example/detail/x/\(id)")) == nil)
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/detail/x/EIMADPBCBFNMBKOPOOJFEKHNKHDBIEEH")) == nil)
        #expect(ChromeWebStore.extensionID(from: URL(string: "https://chromewebstore.google.com/category/extensions")) == nil)
        #expect(ChromeWebStore.extensionID(from: nil) == nil)
    }

    @Test func idsAndDownloads() {
        #expect(ChromeWebStore.isValidID("eimadpbcbfnmbkopoojfekhnkhdbieeh"))
        #expect(!ChromeWebStore.isValidID("eimadpbcbfnmbkopoojfekhnkhdbiee"))
        #expect(!ChromeWebStore.isValidID("eimadpbcbfnmbkopoojfekhnkhdbieez"))
        #expect(!ChromeWebStore.isValidID("../madpbcbfnmbkopoojfekhnkhdbieeh"))
        let url = ChromeWebStore.downloadURL(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh")!
        #expect(url.host() == "clients2.google.com")
        #expect(url.absoluteString.contains("x=id%3Deimadpbcbfnmbkopoojfekhnkhdbieeh%26installsource%3Dondemand%26uc"))
        #expect(ChromeWebStore.downloadURL(id: "nope") == nil)
        #expect(ChromeWebStore.isDownloadHost("clients2.googleusercontent.com"))
        #expect(!ChromeWebStore.isDownloadHost("example.com"))
        #expect(ChromeWebStore.idFromHashPrefix(Data([0x00, 0x1f, 0xf0])) == "aabppa")
    }
}

@Suite struct CRXFileTests {
    let zip = Data("PK\u{03}\u{04}not really a zip".utf8)

    @Test func goodFileIsAccepted() throws {
        let key = CRXFixture.makeKey()
        let (data, id) = CRXFixture.crx(zip: zip, key: key)
        let file = try CRXFile.verified(data)
        #expect(file.id == id)
        #expect(file.zip == zip)
        #expect(try CRXFile.verified(data, expectedID: id).id == id)
    }

    @Test func wrongIDIsRefused() throws {
        let (data, id) = CRXFixture.crx(zip: zip, key: CRXFixture.makeKey())
        let other = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
        #expect(throws: CRXFile.Failure.wrongID(expected: other, found: id)) { try CRXFile.verified(data, expectedID: other) }
    }

    @Test func anIDTheKeyCantSignForIsRefused() {
        let (data, _) = CRXFixture.crx(zip: zip, key: CRXFixture.makeKey(), claimedID: Data(repeating: 0, count: 16))
        #expect(throws: CRXFile.Failure.noMatchingKey) { try CRXFile.verified(data) }
    }

    @Test func aChangedZipIsRefused() {
        let (data, _) = CRXFixture.crx(zip: zip, key: CRXFixture.makeKey(), tamper: true)
        #expect(throws: CRXFile.Failure.badSignature) { try CRXFile.verified(data) }
    }

    @Test func otherFilesAreRefused() {
        #expect(throws: CRXFile.Failure.notCRX) { try CRXFile.verified(zip) }
        #expect(throws: CRXFile.Failure.notCRX) { try CRXFile.verified(Data()) }
        var v2 = Data("Cr24".utf8); v2.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: CRXFile.Failure.unsupportedVersion(2)) { try CRXFile.verified(v2) }
        var short = Data("Cr24".utf8); short.append(contentsOf: [3, 0, 0, 0, 0xff, 0, 0, 0])
        #expect(throws: CRXFile.Failure.badHeader) { try CRXFile.verified(short) }
        let (good, _) = CRXFixture.crx(zip: zip, key: CRXFixture.makeKey())
        #expect(throws: (any Error).self) { try CRXFile.verified(good.prefix(40)) }
    }

    /// A real store file, when one is given (`SG_REAL_CRX=<path>:<id>`); never downloaded here.
    @Test func realStoreFile() throws {
        guard let spec = ProcessInfo.processInfo.environment["SG_REAL_CRX"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        let file = try CRXFile.verified(try Data(contentsOf: URL(fileURLWithPath: parts[0])), expectedID: parts[1])
        #expect(file.zip.prefix(2) == Data("PK".utf8))
    }
}

@Suite struct ExtensionRecordTests {
    @Test func roundTripAndTolerance() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sg-ext-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExtensionStateStore(file: dir.appending(path: "extensions-state.json"))
        #expect(store.loadSettingAsideCorrupt().records.isEmpty)
        let space = UUID()
        var grants = ExtensionRecord.Grants()
        grants.permissions = ["tabs"]
        let record = ExtensionRecord(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", name: "Dark Reader", version: "4.9", source: .store,
                                     fingerprint: "abc", permissions: ["storage"], patterns: ["<all_urls>"], enabledSpaces: [space],
                                     contextIDs: [space: "ctx"], grants: [space: grants], installedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save([record.id: record])
        let loaded = store.loadSettingAsideCorrupt()
        #expect(!loaded.wasCorrupt)
        #expect(loaded.records[record.id] == record)

        try Data("{ not json".utf8).write(to: store.file)
        let corrupt = store.loadSettingAsideCorrupt()
        #expect(corrupt.wasCorrupt && corrupt.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))

        let sparse = #"{"x": {"id": "local-0123abcd", "fingerprint": "f", "enabledSpaces": ["not-a-uuid"], "grants": 5}}"#
        try Data(sparse.utf8).write(to: store.file)
        let tolerant = store.loadSettingAsideCorrupt().records["x"]
        #expect(tolerant?.name == "local-0123abcd")
        #expect(tolerant?.enabledSpaces.isEmpty == true)
        #expect(tolerant?.source == .file)
    }

    @Test func rules() {
        let space = UUID()
        let record = ExtensionRecord(id: "local-0123abcd", name: "X", version: "1", source: .file, fingerprint: "f",
                                     permissions: [], patterns: [], enabledSpaces: [space])
        #expect(ExtensionRules.status(record: record, folderExists: true, currentFingerprint: "f") == .ready)
        #expect(ExtensionRules.status(record: record, folderExists: true, currentFingerprint: "g") == .changed)
        #expect(ExtensionRules.status(record: record, folderExists: true, currentFingerprint: nil) == .changed)
        #expect(ExtensionRules.status(record: record, folderExists: false, currentFingerprint: nil) == .missing)
        #expect(ExtensionRules.runs(record, status: .ready, in: space))
        #expect(!ExtensionRules.runs(record, status: .ready, in: UUID()))
        #expect(!ExtensionRules.runs(record, status: .changed, in: space))
        #expect(ExtensionRules.isValidID("local-0123abcd"))
        #expect(ExtensionRules.isValidID("eimadpbcbfnmbkopoojfekhnkhdbieeh"))
        #expect(!ExtensionRules.isValidID("local-0123ABCD"))
        #expect(!ExtensionRules.isValidID("local-../x"))
        #expect(!ExtensionRules.isValidID(""))
        let id = ExtensionRules.newLocalID(taken: [])
        #expect(ExtensionRules.isValidID(id))
        #expect(ExtensionRules.pattern(forSite: "https://example.com") == "https://example.com/*")
        #expect(ExtensionRules.pattern(forSite: "http://localhost:3000") == "http://localhost/*")
        #expect(ExtensionRules.pattern(forSite: "file:///x") == nil)
        #expect(ExtensionRules.isExtensionFile(URL(fileURLWithPath: "/d/a.XPI")))
        #expect(!ExtensionRules.isExtensionFile(URL(fileURLWithPath: "/d/a.zip")))
    }

    @Test func versionsAndWidening() {
        #expect(ExtensionRules.isNewer("4.9.136", than: "4.9.135"))
        #expect(ExtensionRules.isNewer("2026.1117.1", than: "2026.1116.1650"))
        #expect(ExtensionRules.isNewer("1.10", than: "1.9"))
        #expect(!ExtensionRules.isNewer("1.0", than: "1.0.0"))
        #expect(!ExtensionRules.isNewer("1.0", than: "1.1"))
        #expect(ExtensionRules.isNewer("1.0b", than: "1.0a"))
        #expect(!ExtensionRules.isNewer("", than: "1.0a"))
        let record = ExtensionRecord(id: "local-0123abcd", name: "X", version: "1", source: .store, fingerprint: "f",
                                     permissions: ["storage", "tabs"], patterns: ["<all_urls>"], enabledSpaces: [])
        #expect(!ExtensionRules.widens(record, permissions: ["storage"], patterns: ["<all_urls>"]))
        #expect(!ExtensionRules.widens(record, permissions: [], patterns: []))
        #expect(ExtensionRules.widens(record, permissions: ["storage", "cookies"], patterns: ["<all_urls>"]))
        #expect(ExtensionRules.widens(record, permissions: ["storage"], patterns: ["https://example.com/*"]))
    }

    @Test func siteSettingsKeepDisabledExtensions() throws {
        var settings = SiteSettings()
        settings.disabledExtensions = ["local-0123abcd"]
        #expect(!settings.isDefault)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(SiteSettings.self, from: data) == settings)
        // An older file has no key: nothing switched off.
        let old = try JSONDecoder().decode(SiteSettings.self, from: Data(#"{"camera":"ask"}"#.utf8))
        #expect(old.disabledExtensions.isEmpty)
    }
}
