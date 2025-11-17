import Foundation

/// Represents a reusable TCP tunnel opened through the ADB transport (e.g. `tcp:<port>` services).
public final class ADBTCPStream {
    private let connection: ADBConnection
    private let channel: ADBChannel
    private let lock = NSLock()

    init(connection: ADBConnection, channel: ADBChannel) {
        self.connection = connection
        self.channel = channel
    }

    /// Sends raw bytes over the stream and waits for the device to acknowledge them.
    public func send(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.write(data, to: channel)
    }

    /// Reads the next payload chunk from the device. Returns `nil` when the device closes the channel.
    public func receive() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try connection.readChunk(from: channel)
    }

    /// Closes the underlying ADB channel.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? connection.close(channel: channel)
    }
}
