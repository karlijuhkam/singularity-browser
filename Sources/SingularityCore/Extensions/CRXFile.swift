import CryptoKit
import Foundation
import Security

/// A Chrome extension file (`.crx`, format 3): checked and taken apart.
///
/// Layout: the bytes `Cr24`, version 3 (little-endian UInt32), the header length (UInt32), a
/// protobuf `CrxFileHeader`, then a zip. The header carries the developer's RSA public key and a
/// signature over `"CRX3 SignedData\0" + le32(len) + signed_header_data + zip`;
/// `signed_header_data` is a protobuf whose field 1 is the extension's id as 16 bytes.
///
/// `verified` accepts a file only when that id belongs to one of the header's RSA keys (Chrome's
/// rule: id = SHA-256 of the key) and that key's signature over the zip is good. So a file that
/// claims an id it can't sign for, or whose zip was changed, is refused. (Google adds a second
/// signature of its own; we don't check that one: the download comes over HTTPS from Google.)
public struct CRXFile: Equatable, Sendable {
    /// The extension id (32 letters a…p).
    public let id: String
    /// The zip inside.
    public let zip: Data

    public enum Failure: Error, Equatable, Sendable {
        case notCRX            // wrong magic or too short
        case unsupportedVersion(UInt32)
        case badHeader         // the protobuf couldn't be read
        case noMatchingKey     // no RSA key in the header hashes to the id
        case badSignature
        case wrongID(expected: String, found: String)
    }

    /// Reads and checks `data`. With `expectedID`, the file must be that extension.
    public static func verified(_ data: Data, expectedID: String? = nil) throws -> CRXFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] == 0x43, bytes[1] == 0x72, bytes[2] == 0x32, bytes[3] == 0x34 else { throw Failure.notCRX }
        let version = le32(bytes, 4)
        guard version == 3 else { throw Failure.unsupportedVersion(version) }
        let headerLength = Int(le32(bytes, 8))
        guard headerLength > 0, 12 + headerLength <= bytes.count else { throw Failure.badHeader }
        let header = Array(bytes[12 ..< 12 + headerLength])
        let zip = Data(bytes[(12 + headerLength)...])

        // CrxFileHeader: 2 = sha256_with_rsa (AsymmetricKeyProof), 3 = sha256_with_ecdsa,
        // 10000 = signed_header_data. AsymmetricKeyProof: 1 = public_key, 2 = signature.
        guard let fields = Protobuf.fields(header) else { throw Failure.badHeader }
        guard let signedHeader = fields.last(where: { $0.number == 10000 })?.bytes,
              let signedFields = Protobuf.fields(signedHeader),
              let crxID = signedFields.last(where: { $0.number == 1 })?.bytes, crxID.count == 16 else { throw Failure.badHeader }
        let id = ChromeWebStore.idFromHashPrefix(Data(crxID))
        if let expectedID, expectedID != id { throw Failure.wrongID(expected: expectedID, found: id) }

        var proofs: [(key: [UInt8], signature: [UInt8])] = []
        for field in fields where field.number == 2 {
            guard let proof = Protobuf.fields(field.bytes) else { throw Failure.badHeader }
            if let key = proof.last(where: { $0.number == 1 })?.bytes, let signature = proof.last(where: { $0.number == 2 })?.bytes {
                proofs.append((key, signature))
            }
        }
        guard let proof = proofs.first(where: { ChromeWebStore.extensionID(publicKey: Data($0.key)) == id }) else {
            throw Failure.noMatchingKey
        }

        var signed = Data("CRX3 SignedData".utf8)
        signed.append(0)
        var length = UInt32(signedHeader.count).littleEndian
        withUnsafeBytes(of: &length) { signed.append(contentsOf: $0) }
        signed.append(contentsOf: signedHeader)
        signed.append(zip)
        guard verifyRSA(spki: Data(proof.key), signature: Data(proof.signature), message: signed) else { throw Failure.badSignature }
        return CRXFile(id: id, zip: zip)
    }

    /// RSA PKCS#1 v1.5 with SHA-256. `spki` is a DER SubjectPublicKeyInfo (what CRX files carry);
    /// the Security framework wants the RSAPublicKey inside it.
    static func verifyRSA(spki: Data, signature: Data, message: Data) -> Bool {
        guard let rsaKey = DER.rsaPublicKey(fromSPKI: [UInt8](spki)) else { return false }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(Data(rsaKey) as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// Just enough protobuf to read a CRX header: every field with its number; length-delimited fields
/// keep their bytes, the others (varint, 32/64-bit) are skipped over.
enum Protobuf {
    struct Field { let number: Int; let bytes: [UInt8] }

    static func fields(_ b: [UInt8]) -> [Field]? {
        var i = 0
        var out: [Field] = []
        while i < b.count {
            guard let key = varint(b, &i) else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: guard varint(b, &i) != nil else { return nil }
            case 1: guard i + 8 <= b.count else { return nil }; i += 8
            case 5: guard i + 4 <= b.count else { return nil }; i += 4
            case 2:
                guard let length = varint(b, &i), length <= UInt64(b.count - i) else { return nil }
                out.append(Field(number: number, bytes: Array(b[i ..< i + Int(length)])))
                i += Int(length)
            default: return nil
            }
        }
        return out
    }

    static func varint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let byte = b[i]; i += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

/// The few DER rules needed to take the RSAPublicKey out of a SubjectPublicKeyInfo.
enum DER {
    /// SEQUENCE { SEQUENCE { algorithm, parameters }, BIT STRING { RSAPublicKey } }.
    static func rsaPublicKey(fromSPKI b: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let outer = element(b, &i, tag: 0x30), i == b.count else { return nil }
        var j = 0
        guard element(outer, &j, tag: 0x30) != nil, let bits = element(outer, &j, tag: 0x03), j == outer.count,
              bits.first == 0 else { return nil } // no unused bits
        return Array(bits.dropFirst())
    }

    /// One element with the given tag at `i`: its contents; `i` moves past it.
    static func element(_ b: [UInt8], _ i: inout Int, tag: UInt8) -> [UInt8]? {
        guard i + 2 <= b.count, b[i] == tag else { return nil }
        i += 1
        var length = Int(b[i]); i += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count >= 1, count <= 4, i + count <= b.count else { return nil }
            length = 0
            for _ in 0 ..< count { length = length << 8 | Int(b[i]); i += 1 }
        }
        guard length >= 0, i + length <= b.count else { return nil }
        defer { i += length }
        return Array(b[i ..< i + length])
    }
}
