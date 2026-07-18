import Foundation
import CryptoKit

// Secret chat on the CryptoLayer model: no own server — VK itself is the untrusted "wire".
// Only ciphertext ever travels through VK. Identity is exchanged OUT OF BAND (you share your ID,
// the peer adds it), so there is no MITM window. All keys/crypto stay on the device.
//   identity : Ed25519 — your ID is its public key; sharing/adding it IS the authentication
//   session  : X25519 ECDH -> HKDF-SHA256 -> AES-GCM; the kex key is signed by identity
enum SecretChat {
    static let hMarker = "TKCLH:"   // handshake (kex pub + signature), sent through VK
    static let mMarker = "TKCLM:"   // encrypted message, sent through VK
    static func isMarker(_ t: String) -> Bool { t.hasPrefix(hMarker) || t.hasPrefix(mMarker) }

    // MARK: device keys (in Keychain, never leave the device)

    static var identity: Curve25519.Signing.PrivateKey {
        if let s = Keychain.get("sc_id"), let d = Data(base64Encoded: s),
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.Signing.PrivateKey()
        Keychain.set(k.rawRepresentation.base64EncodedString(), for: "sc_id")
        return k
    }
    static var kex: Curve25519.KeyAgreement.PrivateKey {
        if let s = Keychain.get("sc_kex"), let d = Data(base64Encoded: s),
           let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.KeyAgreement.PrivateKey()
        Keychain.set(k.rawRepresentation.base64EncodedString(), for: "sc_kex")
        return k
    }
    static var myId: String { identity.publicKey.rawRepresentation.base64EncodedString() }

    // MARK: per-VK-peer session record (credentials saved on device, reused, tied to that chat)

    struct Rec: Codable { var idPub: Data; var kexPub: Data? }
    private static func name(_ peer: Int) -> String { "screc_\(peer)" }
    static func rec(_ peer: Int) -> Rec? {
        guard let s = UserDefaults.standard.string(forKey: name(peer)), let d = Data(base64Encoded: s) else { return nil }
        return try? JSONDecoder().decode(Rec.self, from: d)
    }
    private static func save(_ peer: Int, _ r: Rec) {
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d.base64EncodedString(), forKey: name(peer)) }
    }
    static func disable(_ peer: Int) { UserDefaults.standard.removeObject(forKey: name(peer)) }
    static func hasPeerId(_ peer: Int) -> Bool { rec(peer) != nil }
    static func established(_ peer: Int) -> Bool { rec(peer)?.kexPub != nil }

    // Add the peer's out-of-band ID (their identity public key). Resets any old session.
    @discardableResult
    static func addPeer(_ peer: Int, idB64: String) -> Bool {
        let clean = idB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Data(base64Encoded: clean),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: d)) != nil,
              d != identity.publicKey.rawRepresentation else { return false }
        save(peer, Rec(idPub: d, kexPub: nil))
        return true
    }

    // MARK: handshake (sent through VK, but verified against the out-of-band ID)

    static func myHandshake() -> String {
        let kexPub = kex.publicKey.rawRepresentation
        let sig = (try? identity.signature(for: kexPub)) ?? Data()
        let obj = ["k": kexPub.base64EncodedString(), "s": sig.base64EncodedString()]
        return hMarker + ((try? JSONSerialization.data(withJSONObject: obj)) ?? Data()).base64EncodedString()
    }

    enum HS { case established, badIdentity, ignored }

    @discardableResult
    static func processHandshake(_ peer: Int, _ text: String) -> HS {
        guard text.hasPrefix(hMarker), var r = rec(peer),   // peer ID must be added first
              let raw = Data(base64Encoded: String(text.dropFirst(hMarker.count))),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: String],
              let kexB = obj["k"].flatMap({ Data(base64Encoded: $0) }),
              let sigB = obj["s"].flatMap({ Data(base64Encoded: $0) }),
              let idPub = try? Curve25519.Signing.PublicKey(rawRepresentation: r.idPub) else { return .ignored }
        guard idPub.isValidSignature(sigB, for: kexB) else { return .badIdentity }
        r.kexPub = kexB
        save(peer, r)
        return .established
    }

    // MARK: crypto

    private static func sharedKey(_ peer: Int) -> SymmetricKey? {
        guard let kexPub = rec(peer)?.kexPub,
              let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: kexPub),
              let secret = try? kex.sharedSecretFromKeyAgreement(with: pk) else { return nil }
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: Data("TK-SecretChat-v1".utf8),
                                              sharedInfo: Data(), outputByteCount: 32)
    }

    static func encrypt(_ peer: Int, _ text: String) -> String? {
        guard let key = sharedKey(peer),
              let box = try? AES.GCM.seal(Data(text.utf8), using: key),
              let c = box.combined else { return nil }
        return mMarker + c.base64EncodedString()
    }
    static func decrypt(_ peer: Int, _ text: String) -> String? {
        guard text.hasPrefix(mMarker),
              let d = Data(base64Encoded: String(text.dropFirst(mMarker.count))),
              let key = sharedKey(peer),
              let box = try? AES.GCM.SealedBox(combined: d),
              let pt = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    static func safetyNumber(_ peer: Int) -> String? {
        guard let r = rec(peer) else { return nil }
        let mine = identity.publicKey.rawRepresentation
        let (a, b) = mine.lexicographicallyPrecedes(r.idPub) ? (mine, r.idPub) : (r.idPub, mine)
        let digest = Array(SHA256.hash(data: a + b))
        let groups = stride(from: 0, to: 10, by: 2).map { i -> String in
            String(format: "%05d", Int((UInt32(digest[i]) << 8) | UInt32(digest[i + 1])))
        }
        return groups.joined(separator: " ")
    }
}
