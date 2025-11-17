import Foundation

/// Public entry point for establishing a raw ADB session without relying on the adb binary.
public final class ADBKernel {
    public enum KernelError: LocalizedError {
        case disconnected
        case invalidUTF8
        case unsupportedScreenshotEncoding
        case underlying(Error)

        public var errorDescription: String? {
            switch self {
            case .disconnected:
                return "ADB connection has not been established."
            case .invalidUTF8:
                return "Unable to decode UTF-8 data returned by the device."
            case .unsupportedScreenshotEncoding:
                return "The device returned a screenshot that could not be encoded as PNG."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    private let configuration: Configuration
    private var connection: ADBConnection?

    public struct Configuration {
        public let host: String
        public let port: UInt16
        public let authenticator: ADBAuthenticator?
        public let banner: String

        public init(host: String, port: UInt16 = 5555, authenticator: ADBAuthenticator? = nil, banner: String = "host::\0") {
            self.host = host
            self.port = port
            self.authenticator = authenticator
            self.banner = banner
        }
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public convenience init(host: String, port: UInt16 = 5555, authenticator: ADBAuthenticator? = nil) {
        self.init(configuration: Configuration(host: host, port: port, authenticator: authenticator))
    }

    public func connect() throws {
        if let connection {
            _ = connection
            return
        }
        do {
            let newConnection = try ADBConnection(configuration: configuration)
            connection = newConnection
        } catch {
            throw KernelError.underlying(error)
        }
    }

    public func disconnect() {
        connection?.close()
        connection = nil
    }

    @discardableResult
    public func shell(_ command: String) throws -> String {
        let data = try performShell(command)
        guard let output = String(data: data, encoding: .utf8) else {
            throw KernelError.invalidUTF8
        }
        return output
    }

    public func sendKeyEvent(_ keyCode: Int) throws {
        _ = try performShell("input keyevent \(keyCode)")
    }

    public func screenshot() throws -> Data {
        try performShell("screencap -p")
    }

    public func screenshot(to destination: URL) throws {
        let pngData = try screenshot()
        try pngData.write(to: destination)
    }

    private func performShell(_ command: String) throws -> Data {
        if connection == nil {
            try connect()
        }
        guard let connection else { throw KernelError.disconnected }
        return try connection.performShell(command)
    }
}
