import Foundation

/// Lightweight Swift wrapper that exposes common ADB commands so that SwiftUI apps can
/// communicate with Android TV devices.
public struct ADBKernel {
    public enum KernelError: LocalizedError {
        case executableNotFound(String)
        case commandFailed(exitCode: Int32, stderr: String)
        case outputDecodingFailed

        public var errorDescription: String? {
            switch self {
            case .executableNotFound(let path):
                return "Could not find adb executable at \(path)."
            case .commandFailed(let exitCode, let stderr):
                return "adb command failed with exit code \(exitCode): \(stderr)"
            case .outputDecodingFailed:
                return "Failed to decode adb output as UTF-8"
            }
        }
    }

    public struct ADBResult {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    private let adbPath: String
    private let deviceID: String?

    /// Create a kernel instance.
    /// - Parameters:
    ///   - adbPath: Path to the adb executable. Defaults to the result of `which adb`.
    ///   - deviceID: Optional device identifier returned by `adb devices`. When supplied,
    ///              the kernel automatically adds `-s <deviceID>` to each command.
    public init(adbPath: String? = nil, deviceID: String? = nil) throws {
        if let adbPath {
            self.adbPath = adbPath
        } else if let resolved = Self.resolveADBPath() {
            self.adbPath = resolved
        } else {
            throw KernelError.executableNotFound("adb")
        }
        self.deviceID = deviceID
    }

    // MARK: - Public commands

    /// Starts the ADB server.
    @discardableResult
    public func startServer() throws -> ADBResult {
        try run(["start-server"])
    }

    /// Stops the ADB server.
    @discardableResult
    public func killServer() throws -> ADBResult {
        try run(["kill-server"])
    }

    /// Connects to an Android TV over TCP/IP.
    /// - Parameter endpoint: Typically `host:port`.
    @discardableResult
    public func connect(_ endpoint: String) throws -> ADBResult {
        try run(["connect", endpoint])
    }

    /// Disconnects from an Android TV over TCP/IP.
    @discardableResult
    public func disconnect(_ endpoint: String? = nil) throws -> ADBResult {
        var args = ["disconnect"]
        if let endpoint { args.append(endpoint) }
        return try run(args)
    }

    /// Executes arbitrary shell commands on the connected TV.
    @discardableResult
    public func shell(_ command: String) throws -> ADBResult {
        try run(["shell", command])
    }

    /// Sends a key event such as volume control or navigation to the TV.
    /// - Parameter keyCode: Key code as defined by Android's `KeyEvent` constants.
    @discardableResult
    public func sendKeyEvent(_ keyCode: Int) throws -> ADBResult {
        try shell("input keyevent \(keyCode)")
    }

    /// Installs an APK on the device.
    @discardableResult
    public func install(apkAt path: String, replaceExisting: Bool = false) throws -> ADBResult {
        var args = ["install"]
        if replaceExisting { args.append("-r") }
        args.append(path)
        return try run(args)
    }

    /// Captures a screenshot from the Android TV and writes it to the specified path.
    @discardableResult
    public func screenshot(to destination: URL) throws -> ADBResult {
        let tempRemotePath = "/sdcard/adb_kernel_capture.png"
        _ = try shell("screencap -p \(tempRemotePath)")
        let result = try run(["pull", tempRemotePath, destination.path])
        _ = try shell("rm \(tempRemotePath)")
        return result
    }

    // MARK: - Helpers

    private func run(_ arguments: [String]) throws -> ADBResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = Self.injectDeviceID(deviceID, into: arguments)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard let stdoutString = String(data: stdoutData, encoding: .utf8),
              let stderrString = String(data: stderrData, encoding: .utf8)
        else {
            throw KernelError.outputDecodingFailed
        }

        let result = ADBResult(
            exitCode: process.terminationStatus,
            stdout: stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if result.exitCode != 0 {
            throw KernelError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        return result
    }

    static func injectDeviceID(_ deviceID: String?, into arguments: [String]) -> [String] {
        guard let deviceID else { return arguments }
        var newArgs = ["-s", deviceID]
        newArgs.append(contentsOf: arguments)
        return newArgs
    }

    static func resolveADBPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "adb"]

        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }
}
