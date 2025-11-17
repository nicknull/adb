import Foundation

struct ADBSyncStat {
    let mode: UInt32
    let size: UInt32
    let modifiedTime: UInt32
}

final class ADBSyncClient {
    enum SyncError: Error {
        case invalidCommand
        case failure(String)
        case channelClosed
    }

    private let connection: ADBConnection

    init(connection: ADBConnection) {
        self.connection = connection
    }

    func pull(path: String) throws -> Data {
        let channel = try connection.openStream(service: "sync:")
        defer { try? connection.close(channel: channel) }
        try send(command: "RECV", payload: Data(path.utf8), over: channel)
        var buffer = Data()
        while true {
            let frame = try nextFrame(from: channel)
            switch frame.command {
            case "DATA":
                buffer.append(frame.payload)
            case "DONE":
                return buffer
            case "FAIL":
                let message = String(data: frame.payload, encoding: .utf8) ?? "unknown failure"
                throw SyncError.failure(message)
            default:
                throw SyncError.invalidCommand
            }
        }
    }

    func push(data: Data, path: String, permissions: UInt32, modifiedTime: UInt32) throws {
        let channel = try connection.openStream(service: "sync:")
        defer { try? connection.close(channel: channel) }
        let modeString = String(permissions, radix: 8)
        let descriptor = Data("\(path),\(modeString)".utf8)
        try send(command: "SEND", payload: descriptor, over: channel)
        let chunkPayloadLimit = max(1, connection.maximumPayloadSize - 8)
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let chunkSize = min(remaining, chunkPayloadLimit)
            let chunk = data.subdata(in: offset..<(offset + chunkSize))
            try send(command: "DATA", payload: chunk, over: channel)
            offset += chunkSize
        }
        var mtimeLE = modifiedTime.littleEndian
        let donePayload = Data(bytes: &mtimeLE, count: MemoryLayout<UInt32>.size)
        try send(command: "DONE", payload: donePayload, over: channel)
        let response = try nextFrame(from: channel)
        switch response.command {
        case "OKAY":
            return
        case "FAIL":
            let message = String(data: response.payload, encoding: .utf8) ?? "unknown failure"
            throw SyncError.failure(message)
        default:
            throw SyncError.invalidCommand
        }
    }

    func stat(path: String) throws -> ADBSyncStat {
        let channel = try connection.openStream(service: "sync:")
        defer { try? connection.close(channel: channel) }
        try send(command: "STAT", payload: Data(path.utf8), over: channel)
        let frame = try nextFrame(from: channel)
        switch frame.command {
        case "STAT":
            guard frame.payload.count == 12 else {
                throw SyncError.invalidCommand
            }
            let mode = frame.payload.withUnsafeBytes { $0.load(as: UInt32.self) }
            let size = frame.payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let mtime = frame.payload.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
            return ADBSyncStat(mode: mode, size: size, modifiedTime: mtime)
        case "FAIL":
            let message = String(data: frame.payload, encoding: .utf8) ?? "unknown failure"
            throw SyncError.failure(message)
        default:
            throw SyncError.invalidCommand
        }
    }

    private func send(command: String, payload: Data, over channel: ADBChannel) throws {
        guard let commandData = command.data(using: .ascii), commandData.count == 4 else {
            throw SyncError.invalidCommand
        }
        var frame = Data()
        frame.append(commandData)
        var length = UInt32(payload.count).littleEndian
        frame.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        frame.append(payload)
        try connection.write(frame, to: channel)
    }

    private func nextFrame(from channel: ADBChannel) throws -> (command: String, payload: Data) {
        var buffer = pendingReadBuffer[channel.localID] ?? Data()
        func fill(_ required: Int) throws {
            while buffer.count < required {
                guard let chunk = try connection.readChunk(from: channel) else {
                    throw SyncError.channelClosed
                }
                buffer.append(chunk)
            }
        }
        try fill(8)
        let commandData = buffer.prefix(4)
        guard let command = String(data: commandData, encoding: .ascii) else {
            throw SyncError.invalidCommand
        }
        let lengthData = buffer[4..<8]
        let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })
        try fill(8 + length)
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 8)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        pendingReadBuffer[channel.localID] = buffer.isEmpty ? nil : buffer
        return (command, payload)
    }

    private var pendingReadBuffer: [UInt32: Data] = [:]
}
