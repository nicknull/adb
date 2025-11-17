import Foundation

/// `ADBKernelAsyncAdapter` exposes `ADBKernel` operations through Swift Concurrency.
/// All methods run inside an actor so SwiftUI/iOS clients can `await` ADB calls without
/// blocking the main actor.
protocol ADBKernelInterface: AnyObject {
    func connect() throws
    func disconnect()
    func shell(_ command: String) throws -> String
    func sendKeyEvent(_ keyCode: Int) throws
    func screenshot() throws -> Data
    func screenshot(to destination: URL) throws
    func pullFile(_ remotePath: String) throws -> Data
    func pullFile(_ remotePath: String, to destination: URL) throws
    func pushFile(_ data: Data, to remotePath: String, permissions: UInt32, modifiedTime: Date) throws
    func pushFile(from localURL: URL, to remotePath: String, permissions: UInt32, modifiedTime: Date) throws
    func stat(_ remotePath: String) throws -> ADBKernel.FileInfo
    func openTCPStream(toDevicePort port: UInt16) throws -> ADBTCPStream
}

extension ADBKernel: ADBKernelInterface {}

public actor ADBKernelAsyncAdapter {
    private let kernel: ADBKernelInterface

    internal init(kernel: ADBKernelInterface) {
        self.kernel = kernel
    }

    public init(configuration: ADBKernel.Configuration) {
        self.kernel = ADBKernel(configuration: configuration)
    }

    public init(
        host: String,
        port: UInt16 = 5555,
        authenticator: ADBAuthenticator? = nil,
        transportSecurity: ADBKernel.TransportSecurity = .plaintext,
        allowsSocketReuse: Bool = false,
        reuseIdentifier: String? = nil,
        socketOptions: ADBKernel.SocketOptions = .defaults
    ) {
        let configuration = ADBKernel.Configuration(
            host: host,
            port: port,
            authenticator: authenticator,
            transportSecurity: transportSecurity,
            allowsSocketReuse: allowsSocketReuse,
            reuseIdentifier: reuseIdentifier,
            socketOptions: socketOptions
        )
        self.kernel = ADBKernel(configuration: configuration)
    }

    // MARK: - Public API

    public func connect() throws {
        try kernel.connect()
    }

    public func disconnect() {
        kernel.disconnect()
    }

    public func shell(_ command: String) throws -> String {
        try kernel.shell(command)
    }

    public func sendKeyEvent(_ keyCode: Int) throws {
        try kernel.sendKeyEvent(keyCode)
    }

    public func screenshot() throws -> Data {
        try kernel.screenshot()
    }

    public func screenshot(to destination: URL) throws {
        try kernel.screenshot(to: destination)
    }

    public func pullFile(_ remotePath: String) throws -> Data {
        try kernel.pullFile(remotePath)
    }

    public func pullFile(_ remotePath: String, to destination: URL) throws {
        try kernel.pullFile(remotePath, to: destination)
    }

    public func pushFile(
        _ data: Data,
        to remotePath: String,
        permissions: UInt32 = 0o644,
        modifiedTime: Date = Date()
    ) throws {
        try kernel.pushFile(data, to: remotePath, permissions: permissions, modifiedTime: modifiedTime)
    }

    public func pushFile(
        from localURL: URL,
        to remotePath: String,
        permissions: UInt32 = 0o644,
        modifiedTime: Date = Date()
    ) throws {
        try kernel.pushFile(from: localURL, to: remotePath, permissions: permissions, modifiedTime: modifiedTime)
    }

    public func stat(_ remotePath: String) throws -> ADBKernel.FileInfo {
        try kernel.stat(remotePath)
    }

    public func openTCPStream(toDevicePort port: UInt16) throws -> ADBTCPStream {
        try kernel.openTCPStream(toDevicePort: port)
    }
}
