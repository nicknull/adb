import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ADBKernel

final class MockADBServer {
    enum AuthenticationMode {
        case none
        case signatureOnly
        case signatureThenPublicKey
    }

    private struct SyncFile {
        var data: Data
        var mode: UInt32
        var mtime: UInt32
    }

    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var running = false
    private let responseProvider: (String) -> Data
    private let authenticationMode: AuthenticationMode
    private let stateQueue = DispatchQueue(label: "mock.adb.state")
    private var recordedServices: [String] = []
    private var recordedAuthTypes: [UInt32] = []
    private var totalConnections: Int = 0
    private var syncFiles: [String: SyncFile] = [:]

    init(authenticationMode: AuthenticationMode = .none, responseProvider: @escaping (String) -> Data) {
        self.authenticationMode = authenticationMode
        self.responseProvider = responseProvider
    }

    func start() throws -> UInt16 {
        #if canImport(Darwin)
        let socketType = Int32(SOCK_STREAM)
        let protocolType = 0
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        let protocolType = Int32(IPPROTO_TCP)
        #endif

        listenFD = socket(AF_INET, socketType, protocolType)
        guard listenFD >= 0 else { throw NSError(domain: "MockADB", code: 1) }

        var value: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = in_port_t(0).bigEndian

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw NSError(domain: "MockADB", code: 2) }

        listen(listenFD, 1)

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &len)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)

        running = true
        thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread?.start()

        return port
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            #if canImport(Darwin)
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            #else
            Glibc.shutdown(listenFD, Int32(SHUT_RDWR))
            Glibc.close(listenFD)
            #endif
            listenFD = -1
        }
        thread?.cancel()
        thread = nil
    }

    func lastService() -> String? {
        stateQueue.sync { recordedServices.last }
    }

    func observedAuthTypes() -> [UInt32] {
        stateQueue.sync { recordedAuthTypes }
    }

    func connectionsAccepted() -> Int {
        stateQueue.sync { totalConnections }
    }

    func seedSyncFile(path: String, contents: Data, mode: UInt32 = 0o644, mtime: UInt32 = 0) {
        stateQueue.sync {
            syncFiles[path] = SyncFile(data: contents, mode: mode, mtime: mtime)
        }
    }

    func syncFile(at path: String) -> (data: Data, mode: UInt32, mtime: UInt32)? {
        stateQueue.sync {
            guard let file = syncFiles[path] else { return nil }
            return (file.data, file.mode, file.mtime)
        }
    }

    private func record(service: String) {
        stateQueue.sync {
            recordedServices.append(service)
        }
    }

    private func recordAuth(type: UInt32) {
        stateQueue.sync {
            recordedAuthTypes.append(type)
        }
    }

    private func runLoop() {
        while running {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
#if canImport(Darwin)
            let clientFD = Darwin.accept(listenFD, &clientAddr, &len)
#else
            let clientFD = Glibc.accept(listenFD, &clientAddr, &len)
#endif
            if clientFD < 0 {
                continue
            }
            stateQueue.sync { totalConnections += 1 }
            handleClient(fd: clientFD)
#if canImport(Darwin)
            Darwin.close(clientFD)
#else
            Glibc.close(clientFD)
#endif
        }
    }

    private func handleClient(fd: Int32) {
        guard let cnxn = try? readPacket(fd: fd), cnxn.command == ADBCommand.cnxn else {
            return
        }
        guard completeAuthentication(fd: fd, initialCNXN: cnxn) else {
            return
        }

        var nextRemoteID: UInt32 = 100
        while running {
            guard let packet = try? readPacket(fd: fd) else { break }
            switch packet.command {
            case ADBCommand.open:
                let serviceName = String(data: packet.data.dropLast(), encoding: .utf8) ?? ""
                record(service: serviceName)
                let remoteID = nextRemoteID
                nextRemoteID += 1
                let okay = ADBPacket(command: ADBCommand.okay, arg0: remoteID, arg1: packet.arg0)
                try? send(packet: okay, fd: fd)
                if serviceName.hasPrefix("tcp:") {
                    handleTCPStream(fd: fd, hostLocalID: packet.arg0, remoteID: remoteID)
                } else if serviceName == "sync:" {
                    handleSyncService(fd: fd, hostLocalID: packet.arg0, remoteID: remoteID)
                } else {
                    let payload = responseProvider(serviceName)
                    let write = ADBPacket(command: ADBCommand.write, arg0: remoteID, arg1: packet.arg0, data: payload)
                    try? send(packet: write, fd: fd)
                    _ = try? readPacket(fd: fd) // host OKAY
                    let close = ADBPacket(command: ADBCommand.close, arg0: remoteID, arg1: packet.arg0)
                    try? send(packet: close, fd: fd)
                    _ = try? readPacket(fd: fd) // host close ack
                }
            default:
                continue
            }
        }
    }

    private func handleTCPStream(fd: Int32, hostLocalID: UInt32, remoteID: UInt32) {
        while running {
            guard let packet = try? readPacket(fd: fd) else { break }
            switch packet.command {
            case ADBCommand.write where packet.arg0 == hostLocalID:
                let okay = ADBPacket(command: ADBCommand.okay, arg0: remoteID, arg1: hostLocalID)
                try? send(packet: okay, fd: fd)
                let echo = ADBPacket(command: ADBCommand.write, arg0: remoteID, arg1: hostLocalID, data: packet.data)
                try? send(packet: echo, fd: fd)
            case ADBCommand.close where packet.arg0 == hostLocalID:
                let close = ADBPacket(command: ADBCommand.close, arg0: remoteID, arg1: hostLocalID)
                try? send(packet: close, fd: fd)
                _ = try? readPacket(fd: fd)
                return
            default:
                continue
            }
        }
    }

    private func handleSyncService(fd: Int32, hostLocalID: UInt32, remoteID: UInt32) {
        var buffer = Data()
        var pendingSend: (path: String, mode: UInt32, data: Data)?
        while running {
            guard let packet = try? readPacket(fd: fd) else { break }
            switch packet.command {
            case ADBCommand.write where packet.arg0 == hostLocalID:
                let okay = ADBPacket(command: ADBCommand.okay, arg0: remoteID, arg1: hostLocalID)
                try? send(packet: okay, fd: fd)
                buffer.append(packet.data)
                while true {
                    guard let frame = popSyncFrame(from: &buffer) else { break }
                    processSyncFrame(frame, pendingSend: &pendingSend, fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
                }
            case ADBCommand.close where packet.arg0 == hostLocalID:
                let close = ADBPacket(command: ADBCommand.close, arg0: remoteID, arg1: hostLocalID)
                try? send(packet: close, fd: fd)
                _ = try? readPacket(fd: fd)
                return
            default:
                continue
            }
        }
    }

    private func popSyncFrame(from buffer: inout Data) -> (command: String, payload: Data)? {
        guard buffer.count >= 8 else { return nil }
        let commandData = buffer.prefix(4)
        guard let command = String(data: commandData, encoding: .ascii) else { return nil }
        let lengthData = buffer[4..<8]
        let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard buffer.count >= 8 + length else { return nil }
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 8)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        return (command, payload)
    }

    private func processSyncFrame(
        _ frame: (command: String, payload: Data),
        pendingSend: inout (path: String, mode: UInt32, data: Data)?,
        fd: Int32,
        hostLocalID: UInt32,
        remoteID: UInt32
    ) {
        switch frame.command {
        case "RECV":
            let path = String(data: frame.payload, encoding: .utf8) ?? ""
            guard let file = syncFile(at: path) else {
                sendSyncResponse(command: "FAIL", payload: Data("ENOENT".utf8), fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
                return
            }
            let chunkSize = 1024
            var offset = 0
            while offset < file.data.count {
                let end = min(file.data.count, offset + chunkSize)
                let chunk = file.data.subdata(in: offset..<end)
                sendSyncResponse(command: "DATA", payload: chunk, fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
                offset = end
            }
            var zero: UInt32 = 0
            let donePayload = Data(bytes: &zero, count: MemoryLayout<UInt32>.size)
            sendSyncResponse(command: "DONE", payload: donePayload, fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
        case "SEND":
            let descriptor = String(data: frame.payload, encoding: .utf8) ?? ""
            guard let comma = descriptor.lastIndex(of: ",") else {
                sendSyncResponse(command: "FAIL", payload: Data("bad descriptor".utf8), fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
                return
            }
            let path = String(descriptor[..<comma])
            let modeString = String(descriptor[descriptor.index(after: comma)...])
            let mode = UInt32(modeString, radix: 8) ?? 0o644
            pendingSend = (path: path, mode: mode, data: Data())
        case "DATA":
            guard var pending = pendingSend else { return }
            pending.data.append(frame.payload)
            pendingSend = pending
        case "DONE":
            guard let pending = pendingSend else {
                sendSyncResponse(command: "FAIL", payload: Data("no pending send".utf8), fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
                return
            }
            let mtime = frame.payload.withUnsafeBytes { ptr -> UInt32 in
                guard ptr.count >= MemoryLayout<UInt32>.size else { return 0 }
                return ptr.load(as: UInt32.self)
            }
            stateQueue.sync {
                syncFiles[pending.path] = SyncFile(data: pending.data, mode: pending.mode, mtime: mtime)
            }
            pendingSend = nil
            sendSyncResponse(command: "OKAY", payload: Data(), fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
        case "STAT":
            let path = String(data: frame.payload, encoding: .utf8) ?? ""
            if let file = syncFile(at: path) {
                var payload = Data(count: 12)
                payload.withUnsafeMutableBytes { raw in
                    raw.storeBytes(of: file.mode, toByteOffset: 0, as: UInt32.self)
                    raw.storeBytes(of: UInt32(file.data.count), toByteOffset: 4, as: UInt32.self)
                    raw.storeBytes(of: file.mtime, toByteOffset: 8, as: UInt32.self)
                }
                sendSyncResponse(command: "STAT", payload: payload, fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
            } else {
                let zeroPayload = Data(count: 12)
                sendSyncResponse(command: "STAT", payload: zeroPayload, fd: fd, hostLocalID: hostLocalID, remoteID: remoteID)
            }
        default:
            break
        }
    }

    private func sendSyncResponse(command: String, payload: Data, fd: Int32, hostLocalID: UInt32, remoteID: UInt32) {
        guard let commandData = command.data(using: .ascii), commandData.count == 4 else { return }
        var frame = Data()
        frame.append(commandData)
        var length = UInt32(payload.count).littleEndian
        frame.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        frame.append(payload)
        let write = ADBPacket(command: ADBCommand.write, arg0: remoteID, arg1: hostLocalID, data: frame)
        try? send(packet: write, fd: fd)
        _ = try? readPacket(fd: fd)
    }

    private func completeAuthentication(fd: Int32, initialCNXN: ADBPacket) -> Bool {
        switch authenticationMode {
        case .none:
            let response = ADBPacket(command: ADBCommand.cnxn, arg0: initialCNXN.arg0, arg1: 4096, data: "device::\0".data(using: .utf8) ?? Data())
            try? send(packet: response, fd: fd)
            return true
        case .signatureOnly:
            return performAuthExchange(fd: fd, initialCNXN: initialCNXN, requirePublicKey: false)
        case .signatureThenPublicKey:
            return performAuthExchange(fd: fd, initialCNXN: initialCNXN, requirePublicKey: true)
        }
    }

    private func performAuthExchange(fd: Int32, initialCNXN: ADBPacket, requirePublicKey: Bool) -> Bool {
        let token = Data("token".utf8)
        do {
            let authPacket = ADBPacket(command: ADBCommand.auth, arg0: ADBAuth.token, arg1: 0, data: token)
            try send(packet: authPacket, fd: fd)
            guard let signaturePacket = try? readPacket(fd: fd), signaturePacket.command == ADBCommand.auth else { return false }
            recordAuth(type: signaturePacket.arg0)
            guard signaturePacket.arg0 == ADBAuth.signature else { return false }

            if requirePublicKey {
                let secondToken = ADBPacket(command: ADBCommand.auth, arg0: ADBAuth.token, arg1: 0, data: token)
                try send(packet: secondToken, fd: fd)
                guard let keyPacket = try? readPacket(fd: fd), keyPacket.command == ADBCommand.auth else { return false }
                recordAuth(type: keyPacket.arg0)
                guard keyPacket.arg0 == ADBAuth.publicKey else { return false }
            }

            let response = ADBPacket(command: ADBCommand.cnxn, arg0: initialCNXN.arg0, arg1: 4096, data: "device::\0".data(using: .utf8) ?? Data())
            try send(packet: response, fd: fd)
            return true
        } catch {
            return false
        }
    }

    private func readPacket(fd: Int32) throws -> ADBPacket {
        var header = Data(count: 24)
        var bytesRead = 0
        try header.withUnsafeMutableBytes { raw in
            while bytesRead < 24 {
#if canImport(Darwin)
                let result = Darwin.recv(fd, raw.baseAddress!.advanced(by: bytesRead), 24 - bytesRead, 0)
#else
                let result = Glibc.recv(fd, raw.baseAddress!.advanced(by: bytesRead), 24 - bytesRead, 0)
#endif
                if result <= 0 { throw NSError(domain: "MockADB", code: 3) }
                bytesRead += result
            }
        }
        let command = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        let arg0 = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let arg1 = header.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        let length = header.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let checksum = header.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let payload = length > 0 ? try readBytes(fd: fd, length: Int(length)) : Data()
        let computedChecksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        guard checksum == computedChecksum else { throw NSError(domain: "MockADB", code: 4) }
        return ADBPacket(command: command, arg0: arg0, arg1: arg1, data: payload)
    }

    private func readBytes(fd: Int32, length: Int) throws -> Data {
        var buffer = Data(count: length)
        var bytesRead = 0
        try buffer.withUnsafeMutableBytes { raw in
            while bytesRead < length {
#if canImport(Darwin)
                let result = Darwin.recv(fd, raw.baseAddress!.advanced(by: bytesRead), length - bytesRead, 0)
#else
                let result = Glibc.recv(fd, raw.baseAddress!.advanced(by: bytesRead), length - bytesRead, 0)
#endif
                if result <= 0 { throw NSError(domain: "MockADB", code: 5) }
                bytesRead += result
            }
        }
        return buffer
    }

    private func send(packet: ADBPacket, fd: Int32) throws {
        let data = packet.serialize()
        try data.withUnsafeBytes { raw in
            var bytesWritten = 0
            while bytesWritten < data.count {
#if canImport(Darwin)
                let result = Darwin.send(fd, raw.baseAddress!.advanced(by: bytesWritten), data.count - bytesWritten, 0)
#else
                let result = Glibc.send(fd, raw.baseAddress!.advanced(by: bytesWritten), data.count - bytesWritten, 0)
#endif
                if result <= 0 { throw NSError(domain: "MockADB", code: 6) }
                bytesWritten += result
            }
        }
    }
}
