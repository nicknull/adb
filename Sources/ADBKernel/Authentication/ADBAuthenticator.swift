import Foundation

public protocol ADBAuthenticator {
    func sign(authToken: Data) throws -> Data
    var publicKey: Data { get }
}
