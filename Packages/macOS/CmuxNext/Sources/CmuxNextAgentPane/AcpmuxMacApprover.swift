public import Foundation
import CryptoKit
import os
import Security
import CmuxNextCompat

/// This Mac's approver key (peer-route approvals): the P-256 key the app signs a one-time Allow
/// with for a prompt of a peer of this Mac's acpmux (a chat opened with `--host`, which this Mac's
/// daemon mirrors over the peer link). The peer checks the signature against the public key
/// `acpmux host enroll` put in its `mac-approvers.json` (acpmux `hub/mac_approvers.rs`); only the
/// signed answer crosses the link.
///
/// The private key never leaves this process, so an agent on this Mac cannot sign with it:
/// - a signed build (``configure(keychainService:)`` with a service): a Secure Enclave key. Only its
///   encrypted blob is stored, in the data-protection Keychain under this app's access group; the
///   key itself never leaves the enclave, and no other app can read the blob.
/// - a DEV build without a Team ID, or a Mac without a Secure Enclave: a software key in this
///   process's memory only, new each launch (enroll again after a relaunch; the known DEV gap of
///   the person key, identity.md).
public nonisolated final class AcpmuxMacApprover: Sendable {
    // lint:allow one key per app process: the transport signs with it, the host gives its public half to the daemon
    public static let shared = AcpmuxMacApprover()

    /// The domain of the signed message (acpmux `mac_approvers::DOMAIN`).
    static let domain = "acpmux-mac-approver-decision-v1"
    /// How long a signed Allow counts: well under acpmux's `MAX_LIFETIME` (300 s).
    static let lifetime: TimeInterval = 120

    /// The key as bytes (so the lock's state is Sendable): a software key's raw scalar, or the
    /// Secure Enclave's encrypted blob, which only this Mac's enclave can use.
    private enum Signer: Sendable {
        case software(Data)
        case enclave(Data)

        var publicKey: P256.Signing.PublicKey {
            get throws {
                switch self {
                case .software(let raw): try P256.Signing.PrivateKey(rawRepresentation: raw).publicKey
                case .enclave(let blob): try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).publicKey
                }
            }
        }

        func sign(_ message: Data) throws -> P256.Signing.ECDSASignature {
            switch self {
            case .software(let raw): try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: message)
            case .enclave(let blob): try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).signature(for: message)
            }
        }
    }

    private struct State {
        var keychainService: String?
        var signer: Signer?
    }

    // lock carve-out: the key, read synchronously by the transport's Allow; the first read loads it (once, off main at launch)
    private let state = Mutex(State())
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    public init() {}

    /// Where the key lives: the Keychain service of a signed build (the Secure Enclave), or nil
    /// (memory). Called once at launch, before the key is first used.
    public func configure(keychainService: String?) {
        state.withLock { state in
            guard state.signer == nil else { return }
            state.keychainService = keychainService
        }
        // The Keychain read (or the enclave's new key) off the main actor, before the first Allow.
        // task-owner: one key load at launch, then ends
        Task.detached(priority: .utility) { [self] in _ = self.signer() }
    }

    /// ``identity``, read off the main actor (the first read may load the key from the Keychain).
    @concurrent func loadedIdentity() async -> (id: String, publicKey: String) { identity }

    /// The key, made or loaded on first use.
    private func signer() -> Signer {
        state.withLock { state in
            if let signer = state.signer { return signer }
            let made = state.keychainService.flatMap(Self.enclaveKey) ?? .software(P256.Signing.PrivateKey().rawRepresentation)
            state.signer = made
            return made
        }
    }

    /// This Mac's id and public key as acpmux reads them: `mac-` and the first 16 hex digits of the
    /// SHA-256 of the 65-byte uncompressed point, and that point as lowercase hex.
    public var identity: (id: String, publicKey: String) {
        // A software key always parses; an enclave blob this enclave made does too.
        let point = (try? signer().publicKey.x963Representation) ?? Data()
        let digest = SHA256.hash(data: point).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ("mac-" + digest, Self.hex(point))
    }

    /// `_meta.acpmux.approverDecision` for a one-time Allow of `permission` (with its
    /// `answers`, for a question), or nil when the key cannot sign or the answers have no
    /// canonical form.
    func decision(instance: String, session: String, permission: String, toolCall: String, option: String,
                  nonce: String, answers: Any?, now: Date = Date()) -> [String: any Sendable]? {
        let digest: String
        if let answers, !(answers is NSNull) {
            guard let canonical = AcpmuxSecretKey.canonicalDigest(answers) else { return nil }
            digest = canonical
        } else {
            digest = ""
        }
        let id = identity.id
        let expiresAt = UInt64(now.timeIntervalSince1970 + Self.lifetime)
        let message = Self.message(instance: instance, mac: id, session: session, permission: permission,
                                   toolCall: toolCall, option: option, nonce: nonce, expiresAt: expiresAt, answers: digest)
        do {
            let signature = try signer().sign(message)
            return ["approver": id, "expiresAt": expiresAt, "signature": Self.hex(signature.rawRepresentation)]
        } catch {
            Self.logger.error("mac approver could not sign: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The signed bytes (acpmux `mac_approvers::message`): the domain, then each part after a NUL.
    static func message(instance: String, mac: String, session: String, permission: String, toolCall: String,
                        option: String, nonce: String, expiresAt: UInt64, answers: String) -> Data {
        var out = Data(domain.utf8)
        for part in [instance, mac, session, permission, toolCall, option, nonce, String(expiresAt), answers] {
            out.append(0)
            out.append(contentsOf: Data(part.utf8))
        }
        return out
    }

    /// Gives this Mac's acpmux the public key, so `acpmux host enroll` there knows which key to
    /// enroll on a peer (`_acpmux/mac_approver_set`, the person only). Once per daemon process,
    /// off the pane's connect path.
    static func register(_ environment: AcpmuxEnvironment, pid: Int32?) {
        // task-owner: one short person connection (5 s deadline at most) per daemon process
        Task { @MainActor in await registerNow(environment, pid: pid) }
    }

    @MainActor
    private static func registerNow(_ environment: AcpmuxEnvironment, pid: Int32?) async {
        let key = "\(environment.socketPath)#\(pid ?? -1)"
        guard !registered.contains(key) else { return }
        guard let line = await AcpmuxPersonLine.open(environment) else { return }
        defer { line.close() }
        guard line.isPerson else { return }
        let identity = await shared.loadedIdentity()
        let name = await MacName().displayName()
        guard await line.call("_acpmux/mac_approver_set", ["id": identity.id, "publicKey": identity.publicKey, "name": name]) != nil else {
            // A daemon too old for peer-route approvals: nothing to give it.
            return
        }
        registered.insert(key)
    }

    @MainActor private static var registered: Set<String> = []

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The Secure Enclave key under `service`, made and stored on first use; nil without an
    /// enclave or when the Keychain refuses (the caller then keeps a memory key).
    private static func enclaveKey(service: String) -> Signer? {
        guard SecureEnclave.isAvailable else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "mac-approver", kSecAttrSynchronizable as String: false,
                                    kSecUseDataProtectionKeychain as String: true]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        if status == errSecSuccess, let blob = out as? Data,
           (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)) != nil {
            return .enclave(blob)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, &error),
              let made = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else { return nil }
        if status == errSecSuccess { _ = SecItemDelete(query as CFDictionary) }
        var add = query
        add[kSecValueData as String] = made.dataRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            logger.error("mac approver key not stored: \(added, privacy: .public); a memory key this launch")
            return nil
        }
        return .enclave(made.dataRepresentation)
    }
}
