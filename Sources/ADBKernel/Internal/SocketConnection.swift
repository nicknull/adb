import Foundation

protocol SocketConnection {
    func send(_ data: Data) throws
    func receive(length: Int) throws -> Data
    func close()
}

enum SocketError: Error, LocalizedError {
    case connectionFailed(String)
    case sendFailed
    case receiveFailed
    case sslUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Failed to connect: \(reason)"
        case .sendFailed:
            return "Unable to send bytes over the socket"
        case .receiveFailed:
            return "Unable to receive bytes from the socket"
        case .sslUnavailable:
            return "TLS/SSL is not available on this platform"
        }
    }
}
