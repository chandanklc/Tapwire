import Foundation
import Security

public enum CertificateTrustStatus: Equatable, Sendable {
    case notInstalled
    case installedNotTrusted
    case trusted

    public var title: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .installedNotTrusted: return "Installed, not trusted"
        case .trusted: return "Trusted"
        }
    }
}

/// macOS keychain / trust-settings helpers for the root CA.
public enum CertificateTrust {
    private static func secCertificate(_ der: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, der as CFData)
    }

    /// Whether macOS currently trusts the certificate as a root (via trust settings).
    public static func isTrusted(der: Data) -> Bool {
        guard let cert = secCertificate(der) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    public static func isInKeychain(der: Data) -> Bool {
        guard let cert = secCertificate(der) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchItemList as String: [cert],
            kSecReturnRef as String: true,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess { return true }
        // Fallback: compare by label (subject summary).
        let summary = SecCertificateCopySubjectSummary(cert) as String? ?? ""
        let q2: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: summary,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(q2 as CFDictionary, &items) == errSecSuccess else { return false }
        if let list = items as? [Data] { return list.contains(der) }
        if let one = items as? Data { return one == der }
        return false
    }

    /// Validates a leaf against `caDER` as the only anchor, with Apple's SSL server policy for `host`.
    public static func validateServerCertificate(leafDER: Data, caDER: Data, host: String) -> (Bool, String?) {
        guard let leaf = secCertificate(leafDER), let ca = secCertificate(caDER) else { return (false, "bad DER") }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, ca] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return (false, "SecTrustCreate failed") }
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        let ok = SecTrustEvaluateWithError(trust, &error)
        return (ok, error.map { CFErrorCopyDescription($0) as String })
    }

    public static func status(der: Data) -> CertificateTrustStatus {
        if isTrusted(der: der) { return .trusted }
        return isInKeychain(der: der) ? .installedNotTrusted : .notInstalled
    }

    /// Adds the certificate to the login keychain (not trusted yet).
    public static func addToLoginKeychain(der: Data) throws {
        guard let cert = secCertificate(der) else { throw CertificateError.invalidCertificate }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw CertificateError.keychain(status) }
    }

    public static func removeFromKeychain(der: Data) {
        guard let cert = secCertificate(der) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchItemList as String: [cert],
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Adds the certificate to the login keychain and marks it trusted for this user.
    /// macOS shows its own password / Touch ID confirmation for the trust change.
    public static func installAndTrust(pemFile: URL) async throws {
        let keychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        let result = try await ProcessRunner.run("/usr/bin/security",
                                                 ["add-trusted-cert", "-r", "trustRoot", "-k", keychain, pemFile.path])
        guard result.status == 0 else {
            throw CertificateError.command(result.stderr.isEmpty ? "security exited with \(result.status)" : result.stderr)
        }
    }

    /// Removes user trust settings and the certificate.
    public static func untrustAndRemove(pemFile: URL, der: Data) async {
        _ = try? await ProcessRunner.run("/usr/bin/security", ["remove-trusted-cert", pemFile.path])
        removeFromKeychain(der: der)
    }
}

/// Runs a command off the main thread.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ launchPath: String, _ args: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try runSync(launchPath, args))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public static func runSync(_ launchPath: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
