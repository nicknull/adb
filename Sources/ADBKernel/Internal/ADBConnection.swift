import Foundation

final class ADBConnection {
    enum ConnectionError: Error {
        case handshakeFailed
        case authenticationRequired
        case invalidPacket
        case channelClosed
        case sslUnavailable
    }

    private let configuration: ADBKernel.Configuration
    private let socket: SocketConnection
    private var nextLocalID: UInt32 = 1
    private var maxPayload: UInt32 = 256 * 1024
    private var remoteMaxPayload: UInt32 = 4096
    private var pendingPackets: [UInt32: [ADBPacket]] = [:]
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private(set) var isClosed = false

    init(configuration: ADBKernel.Configuration) throws {
        self.configuration = configuration
        switch configuration.transportSecurity {
        case .plaintext:
            self.socket = try TCPSocket(host: configuration.host, port: configuration.port, options: configuration.socketOptions)
#if canImport(Network)
        case .tls(let tlsConfiguration):
            self.socket = try TLSSocket(host: configuration.host, port: configuration.port, configuration: tlsConfiguration)
#else
        case .tls(_):
            throw ConnectionError.sslUnavailable
#endif
        }
        try performHandshake()
    }

    func close() {
        socket.close()
        isClosed = true
    }

    func performShell(_ command: String) throws -> Data {
        let service = "shell:\(command)"
        let channel = try openChannel(named: service)
        defer { try? close(channel: channel) }
        return try drain(channel: channel)
    }

    func openStream(service: String) throws -> ADBChannel {
        try openChannel(named: service)
    }

    func write(_ data: Data, to channel: ADBChannel) throws {
        guard channel.isOpen else { throw ConnectionError.channelClosed }
        try send(packet: ADBPacket(command: ADBCommand.write, arg0: channel.localID, arg1: channel.remoteID, data: data))
        let response = try nextPacket(for: channel)
        guard response.command == ADBCommand.okay else {
            throw ConnectionError.invalidPacket
        }
    }

    func readChunk(from channel: ADBChannel) throws -> Data? {
        guard channel.isOpen else { return nil }
        while true {
            let packet = try nextPacket(for: channel)
            switch packet.command {
            case ADBCommand.write:
                try send(packet: ADBPacket(command: ADBCommand.okay, arg0: channel.localID, arg1: channel.remoteID))
                return packet.data
            case ADBCommand.close:
                channel.markClosed()
                try send(packet: ADBPacket(command: ADBCommand.close, arg0: channel.localID, arg1: channel.remoteID))
                return nil
            default:
                continue
            }
        }
    }

    private func performHandshake() throws {
        try send(packet: ADBPacket(
            command: ADBCommand.cnxn,
            arg0: 0x01000000,
            arg1: maxPayload,
            data: configuration.banner.data(using: .utf8) ?? Data()
        ))

        var sentSignature = false
        var sentPublicKey = false

        while true {
            let packet = try readPacket()
            switch packet.command {
            case ADBCommand.cnxn:
                remoteMaxPayload = packet.arg1
                return
            case ADBCommand.auth where packet.arg0 == ADBAuth.token:
                guard let authenticator = configuration.authenticator else {
                    throw ConnectionError.authenticationRequired
                }
                if !sentSignature {
                    let signature = try authenticator.sign(authToken: packet.data)
                    try send(packet: ADBPacket(command: ADBCommand.auth, arg0: ADBAuth.signature, arg1: 0, data: signature))
                    sentSignature = true
                } else if !sentPublicKey {
                    try send(packet: ADBPacket(command: ADBCommand.auth, arg0: ADBAuth.publicKey, arg1: 0, data: authenticator.publicKey))
                    sentPublicKey = true
                } else {
                    throw ConnectionError.handshakeFailed
                }
            default:
                throw ConnectionError.handshakeFailed
            }
        }
    }

    private func openChannel(named name: String) throws -> ADBChannel {
        var serviceName = name
        if !serviceName.hasSuffix("\0") {
            serviceName.append("\0")
        }
        let localID = nextLocalID
        nextLocalID += 1
        guard let data = serviceName.data(using: .utf8) else {
            throw ConnectionError.invalidPacket
        }
        try send(packet: ADBPacket(command: ADBCommand.open, arg0: localID, arg1: 0, data: data))
        while true {
            let packet = try readPacket()
            switch packet.command {
            case ADBCommand.okay where packet.arg1 == localID:
                return ADBChannel(localID: localID, remoteID: packet.arg0)
            case ADBCommand.close where packet.arg1 == localID:
                throw ConnectionError.channelClosed
            default:
                continue
            }
        }
    }

    func close(channel: ADBChannel) throws {
        guard channel.isOpen else { return }
        channel.markClosed()
        try send(packet: ADBPacket(command: ADBCommand.close, arg0: channel.localID, arg1: channel.remoteID))
    }

    private func drain(channel: ADBChannel) throws -> Data {
        var buffer = Data()
        while true {
            guard let chunk = try readChunk(from: channel) else {
                return buffer
            }
            buffer.append(chunk)
        }
    }

    private func send(packet: ADBPacket) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        try socket.send(packet.serialize())
    }

    private func readPacket() throws -> ADBPacket {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        return try readPacketUnlocked()
    }

    private func readPacketUnlocked() throws -> ADBPacket {
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

    private func nextPacket(for channel: ADBChannel) throws -> ADBPacket {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        if var queued = pendingPackets[channel.localID], !queued.isEmpty {
            let packet = queued.removeFirst()
            pendingPackets[channel.localID] = queued.isEmpty ? nil : queued
            return packet
        }
        while true {
            let packet = try readPacketUnlocked()
            if packet.arg1 == channel.localID {
                return packet
            }
            pendingPackets[packet.arg1, default: []].append(packet)
        }
    }
}

final class ADBChannel {
    let localID: UInt32
    let remoteID: UInt32
    private(set) var isOpen = true

    init(localID: UInt32, remoteID: UInt32) {
        self.localID = localID
        self.remoteID = remoteID
    }

    func markClosed() {
        isOpen = false
    }
}
