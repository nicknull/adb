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
    private var pooledConnection: ConnectionLease?
    private var directConnection: ADBConnection?

    public struct Configuration {
        public let host: String
        public let port: UInt16
        public let authenticator: ADBAuthenticator?
        public let banner: String
        public let transportSecurity: TransportSecurity
        public let allowsSocketReuse: Bool
        public let reuseIdentifier: String?
        public let socketOptions: SocketOptions

        public init(
            host: String,
            port: UInt16 = 5555,
            authenticator: ADBAuthenticator? = nil,
            banner: String = "host::\0",
            transportSecurity: TransportSecurity = .plaintext,
            allowsSocketReuse: Bool = false,
            reuseIdentifier: String? = nil,
            socketOptions: SocketOptions = .defaults
        ) {
            self.host = host
            self.port = port
            self.authenticator = authenticator
            self.banner = banner
            self.transportSecurity = transportSecurity
            self.allowsSocketReuse = allowsSocketReuse
            self.reuseIdentifier = reuseIdentifier
            self.socketOptions = socketOptions
        }
    }

    public enum TransportSecurity: Hashable {
        case plaintext
        case tls(TLSConfiguration)
    }

    public struct TLSConfiguration: Hashable {
        public let pinnedCertificates: [Data]
        public let allowUntrustedCertificates: Bool

        public init(pinnedCertificates: [Data] = [], allowUntrustedCertificates: Bool = false) {
            self.pinnedCertificates = pinnedCertificates
            self.allowUntrustedCertificates = allowUntrustedCertificates
        }
    }

    public struct SocketOptions: Hashable {
        public let reuseAddress: Bool
        public let reusePort: Bool

        public init(reuseAddress: Bool = true, reusePort: Bool = true) {
            self.reuseAddress = reuseAddress
            self.reusePort = reusePort
        }

        public static let defaults = SocketOptions()
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        disconnect()
    }

    public convenience init(
        host: String,
        port: UInt16 = 5555,
        authenticator: ADBAuthenticator? = nil,
        transportSecurity: TransportSecurity = .plaintext,
        allowsSocketReuse: Bool = false,
        reuseIdentifier: String? = nil,
        socketOptions: SocketOptions = .defaults
    ) {
        self.init(
            configuration: Configuration(
                host: host,
                port: port,
                authenticator: authenticator,
                transportSecurity: transportSecurity,
                allowsSocketReuse: allowsSocketReuse,
                reuseIdentifier: reuseIdentifier,
                socketOptions: socketOptions
            )
        )
    }

    public func connect() throws {
        if activeConnection != nil { return }
        do {
            if configuration.allowsSocketReuse {
                pooledConnection = try ADBConnectionPool.shared.acquire(for: configuration)
            } else {
                directConnection = try ADBConnection(configuration: configuration)
            }
        } catch {
            throw KernelError.underlying(error)
        }
    }

    public func disconnect() {
        if configuration.allowsSocketReuse {
            pooledConnection?.release()
            pooledConnection = nil
        } else {
            directConnection?.close()
            directConnection = nil
        }
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

    public struct FileInfo {
        public let path: String
        public let size: UInt32
        public let permissions: UInt32
        public let modifiedTime: Date
    }

    public func pullFile(_ remotePath: String) throws -> Data {
        let syncClient = try makeSyncClient()
        return try syncClient.pull(path: remotePath)
    }

    public func pullFile(_ remotePath: String, to destination: URL) throws {
        let data = try pullFile(remotePath)
        try data.write(to: destination)
    }

    public func pushFile(_ data: Data, to remotePath: String, permissions: UInt32 = 0o644, modifiedTime: Date = Date()) throws {
        let syncClient = try makeSyncClient()
        let timestamp = UInt32(modifiedTime.timeIntervalSince1970)
        try syncClient.push(data: data, path: remotePath, permissions: permissions, modifiedTime: timestamp)
    }

    public func pushFile(from localURL: URL, to remotePath: String, permissions: UInt32 = 0o644, modifiedTime: Date = Date()) throws {
        let data = try Data(contentsOf: localURL)
        try pushFile(data, to: remotePath, permissions: permissions, modifiedTime: modifiedTime)
    }

    public func stat(_ remotePath: String) throws -> FileInfo {
        let syncClient = try makeSyncClient()
        let stat = try syncClient.stat(path: remotePath)
        let modified = Date(timeIntervalSince1970: TimeInterval(stat.modifiedTime))
        return FileInfo(path: remotePath, size: stat.size, permissions: stat.mode, modifiedTime: modified)
    }

    private func performShell(_ command: String) throws -> Data {
        if activeConnection == nil {
            try connect()
        }
        guard let connection = activeConnection else { throw KernelError.disconnected }
        return try connection.performShell(command)
    }

    public func openTCPStream(toDevicePort port: UInt16) throws -> ADBTCPStream {
        if activeConnection == nil {
            try connect()
        }
        guard let connection = activeConnection else { throw KernelError.disconnected }
        let channel = try connection.openStream(service: "tcp:\(port)")
        return ADBTCPStream(connection: connection, channel: channel)
    }

    private var activeConnection: ADBConnection? {
        if let lease = pooledConnection {
            return lease.connection
        }
        return directConnection
    }

    private func makeSyncClient() throws -> ADBSyncClient {
        if activeConnection == nil {
            try connect()
        }
        guard let connection = activeConnection else { throw KernelError.disconnected }
        return ADBSyncClient(connection: connection)
    }
}
