import Foundation
import CryptoKit

// E2E secret chat over VK, following CryptoLayer's model — but done entirely on-device:
// keys/plaintext never leave the phone; VK only ever carries ciphertext.
//   identity  : Ed25519 (long-term, TOFU-verified via a safety number)
//   handshake : X25519 ECDH -> HKDF-SHA256 -> AES key; kex key signed by identity
//   messages  : AES-GCM (CryptoKit combined = nonce+ct+tag), base64, sent as a marked VK message
enum SecretChat {
    static let initMarker = "TKCL1I:"      // handshake: identity + kex pub + signature
    static let msgMarker = "TKCL1M:"       // encrypted message
    static func isMarker(_ t: String) -> Bool { t.hasPrefix(initMarker) || t.hasPrefix(msgMarker) }

    // MARK: device long-term keys (per account), stored in Keychain (device-only)

    static func identity(_ own: Int) -> Curve25519.Signing.PrivateKey {
        let name = "cl_id_\(own)"
        if let s = Keychain.get(name), let d = Data(base64Encoded: s),
           let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.Signing.PrivateKey()
        Keychain.set(k.rawRepresentation.base64EncodedString(), for: name)
        return k
    }

    static func kex(_ own: Int) -> Curve25519.KeyAgreement.PrivateKey {
        let name = "cl_kex_\(own)"
        if let s = Keychain.get(name), let d = Data(base64Encoded: s),
           let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) { return k }
        let k = Curve25519.KeyAgreement.PrivateKey()
        Keychain.set(k.rawRepresentation.base64EncodedString(), for: name)
        return k
    }

    // MARK: peer keys (public, trust-on-first-use)

    struct PeerKeys: Codable { let idPub: Data; let kexPub: Data }
    private static func peerName(_ own: Int, _ peer: Int) -> String { "clpeer_\(own)_\(peer)" }

    static func peerKeys(_ own: Int, _ peer: Int) -> PeerKeys? {
        guard let s = UserDefaults.standard.string(forKey: peerName(own, peer)),
              let d = Data(base64Encoded: s) else { return nil }
        return try? JSONDecoder().decode(PeerKeys.self, from: d)
    }
    private static func store(_ own: Int, _ peer: Int, _ pk: PeerKeys) {
        if let d = try? JSONEncoder().encode(pk) {
            UserDefaults.standard.set(d.base64EncodedString(), forKey: peerName(own, peer))
        }
    }
    static func forget(_ own: Int, _ peer: Int) {
        UserDefaults.standard.removeObject(forKey: peerName(own, peer))
    }
    static func established(_ own: Int, _ peer: Int) -> Bool { peerKeys(own, peer) != nil }

    // MARK: handshake

    static func myInit(own: Int, peer: Int) -> String {
        let id = identity(own), kx = kex(own)
        let kexPub = kx.publicKey.rawRepresentation
        let sig = (try? id.signature(for: kexPub)) ?? Data()
        let obj = ["i": id.publicKey.rawRepresentation.base64EncodedString(),
                   "k": kexPub.base64EncodedString(),
                   "s": sig.base64EncodedString()]
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return initMarker + json.base64EncodedString()
    }

    enum InitResult { case established, changedIdentity, invalid }

    @discardableResult
    static func processInit(own: Int, peer: Int, text: String) -> InitResult {
        guard text.hasPrefix(initMarker),
              let raw = Data(base64Encoded: String(text.dropFirst(initMarker.count))),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: String],
              let idB = obj["i"].flatMap({ Data(base64Encoded: $0) }),
              let kexB = obj["k"].flatMap({ Data(base64Encoded: $0) }),
              let sigB = obj["s"].flatMap({ Data(base64Encoded: $0) }),
              let idPub = try? Curve25519.Signing.PublicKey(rawRepresentation: idB)
        else { return .invalid }
        // kex key must be signed by the claimed identity
        guard idPub.isValidSignature(sigB, for: kexB) else { return .invalid }
        // TOFU: refuse to silently replace a known identity (MITM guard)
        if let existing = peerKeys(own, peer), existing.idPub != idB { return .changedIdentity }
        store(own, peer, PeerKeys(idPub: idB, kexPub: kexB))
        return .established
    }

    // MARK: crypto

    private static func sharedKey(_ own: Int, _ peer: Int) -> SymmetricKey? {
        guard let p = peerKeys(own, peer),
              let peerKexPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: p.kexPub),
              let secret = try? kex(own).sharedSecretFromKeyAgreement(with: peerKexPub) else { return nil }
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: Data("TK-CryptoLayer-v1".utf8),
                                              sharedInfo: Data(), outputByteCount: 32)
    }

    static func encrypt(own: Int, peer: Int, _ plaintext: String) -> String? {
        guard let key = sharedKey(own, peer),
              let box = try? AES.GCM.seal(Data(plaintext.utf8), using: key),
              let combined = box.combined else { return nil }
        return msgMarker + combined.base64EncodedString()
    }

    static func decrypt(own: Int, peer: Int, _ text: String) -> String? {
        guard text.hasPrefix(msgMarker),
              let d = Data(base64Encoded: String(text.dropFirst(msgMarker.count))),
              let key = sharedKey(own, peer),
              let box = try? AES.GCM.SealedBox(combined: d),
              let pt = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    // MARK: safety number (compare out-of-band to detect MITM)

    static func safetyNumber(own: Int, peer: Int) -> String? {
        guard let p = peerKeys(own, peer) else { return nil }
        let mine = identity(own).publicKey.rawRepresentation
        let (x, y) = mine.lexicographicallyPrecedes(p.idPub) ? (mine, p.idPub) : (p.idPub, mine)
        let digest = Array(SHA256.hash(data: x + y))
        let groups = stride(from: 0, to: 10, by: 2).map { i -> String in
            let v = (UInt16(digest[i]) << 8) | UInt16(digest[i + 1])
            return String(format: "%05d", v % 100000)
        }
        return groups.joined(separator: " ")
    }
}
