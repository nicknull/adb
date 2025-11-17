import Foundation

final class ADBConnection {
    enum ConnectionError: Error {
        case handshakeFailed
        case authenticationRequired
        case invalidPacket
        case channelClosed
    }

    private let configuration: ADBKernel.Configuration
    private let socket: TCPSocket
    private var nextLocalID: UInt32 = 1
    private var maxPayload: UInt32 = 256 * 1024
    private var remoteMaxPayload: UInt32 = 4096

    init(configuration: ADBKernel.Configuration) throws {
        self.configuration = configuration
        self.socket = try TCPSocket(host: configuration.host, port: configuration.port)
        try performHandshake()
    }

    func close() {
        socket.close()
    }

    func performShell(_ command: String) throws -> Data {
        let service = "shell:\(command)\0"
        let channel = try openChannel(named: service)
        defer { try? close(channel: channel) }
        return try drain(channel: channel)
    }

    private func performHandshake() throws {
        try send(packet: ADBPacket(
            command: ADBCommand.cnxn,
            arg0: 0x01000000,
            arg1: maxPayload,
            data: configuration.banner.data(using: .utf8) ?? Data()
        ))

        while true {
            let packet = try readPacket()
            switch packet.command {
            case ADBCommand.cnxn:
                remoteMaxPayload = packet.arg1
                return
            case ADBCommand.auth:
                guard let authenticator = configuration.authenticator else {
                    throw ConnectionError.authenticationRequired
                }
                switch packet.arg0 {
                case 1: // token
                    let signature = try authenticator.sign(authToken: packet.data)
                    try send(packet: ADBPacket(command: ADBCommand.auth, arg0: 2, arg1: 0, data: signature))
                case 2: // signature rejected, send public key
                    try send(packet: ADBPacket(command: ADBCommand.auth, arg0: 3, arg1: 0, data: authenticator.publicKey))
                default:
                    throw ConnectionError.handshakeFailed
                }
            default:
                throw ConnectionError.handshakeFailed
            }
        }
    }

    private func openChannel(named name: String) throws -> Channel {
        let localID = nextLocalID
        nextLocalID += 1
        guard let data = name.data(using: .utf8) else {
            throw ConnectionError.invalidPacket
        }
        try send(packet: ADBPacket(command: ADBCommand.open, arg0: localID, arg1: 0, data: data))
        while true {
            let packet = try readPacket()
            switch packet.command {
            case ADBCommand.okay where packet.arg1 == localID:
                return Channel(localID: localID, remoteID: packet.arg0)
            case ADBCommand.close where packet.arg1 == localID:
                throw ConnectionError.channelClosed
            default:
                continue
            }
        }
    }

    private func close(channel: Channel) throws {
        try send(packet: ADBPacket(command: ADBCommand.close, arg0: channel.localID, arg1: channel.remoteID))
    }

    private func drain(channel: Channel) throws -> Data {
        var buffer = Data()
        while true {
            let packet = try readPacket()
            switch packet.command {
            case ADBCommand.write where packet.arg0 == channel.remoteID:
                buffer.append(packet.data)
                try send(packet: ADBPacket(command: ADBCommand.okay, arg0: channel.localID, arg1: channel.remoteID))
            case ADBCommand.close where packet.arg0 == channel.remoteID:
                try send(packet: ADBPacket(command: ADBCommand.close, arg0: channel.localID, arg1: channel.remoteID))
                return buffer
            default:
                continue
            }
        }
    }

    private func send(packet: ADBPacket) throws {
        try socket.send(packet.serialize())
    }

    private func readPacket() throws -> ADBPacket {
        let header = try socket.receive(length: 24)
        let command = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        let arg0 = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let arg1 = header.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        let length = header.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let checksum = header.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let magic = header.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }

        guard magic == command ^ 0xFFFFFFFF else {
            throw ConnectionError.invalidPacket
        }

        let payload = length > 0 ? try socket.receive(length: Int(length)) : Data()
        let computedChecksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        guard checksum == computedChecksum else {
            throw ConnectionError.invalidPacket
        }

        return ADBPacket(command: command, arg0: arg0, arg1: arg1, data: payload)
    }
}

private struct Channel {
    let localID: UInt32
    let remoteID: UInt32
}
