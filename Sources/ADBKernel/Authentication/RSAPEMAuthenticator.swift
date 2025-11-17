#if canImport(Security)
import Foundation
import Security

public final class RSAPEMAuthenticator: ADBAuthenticator {
    private let privateKey: SecKey
    public let publicKey: Data

    /// - Parameters:
    ///   - pemPrivateKey: Contents of the `adbkey` private key in PEM format.
    ///   - adbPublicKey: The exact text contained in the matching `adbkey.pub` file (base64 plus the comment).
    public init(pemPrivateKey: String, adbPublicKey: String) throws {
        let cleaned = RSAPEMAuthenticator.stripHeaders(from: pemPrivateKey)
        guard let keyData = Data(base64Encoded: cleaned) else {
            throw NSError(domain: "ADBKernel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid PEM contents"])
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: keyData.count * 8
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "ADBKernel", code: -2, userInfo: nil)
        }
        self.privateKey = privateKey
        self.publicKey = RSAPEMAuthenticator.preparePublicKeyPayload(from: adbPublicKey)
    }

    public func sign(authToken: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA1, authToken as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "ADBKernel", code: -4, userInfo: nil)
        }
        return signature
    }

    private static func stripHeaders(from pem: String) -> String {
        return pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private static func preparePublicKeyPayload(from adbPublicKey: String) -> Data {
        let trimmed = adbPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var buffer = Data(trimmed.utf8)
        if buffer.last != 0 {
            buffer.append(0)
        }
        return buffer
    }
}
#endif
