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

    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var running = false
    private let responseProvider: (String) -> Data
    private let authenticationMode: AuthenticationMode
    private let stateQueue = DispatchQueue(label: "mock.adb.state")
    private var recordedServices: [String] = []
    private var recordedAuthTypes: [UInt32] = []

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
                let payload = responseProvider(serviceName)
                let write = ADBPacket(command: ADBCommand.write, arg0: remoteID, arg1: packet.arg0, data: payload)
                try? send(packet: write, fd: fd)
                _ = try? readPacket(fd: fd) // host OKAY
                let close = ADBPacket(command: ADBCommand.close, arg0: remoteID, arg1: packet.arg0)
                try? send(packet: close, fd: fd)
                _ = try? readPacket(fd: fd) // host close ack
            default:
                continue
            }
        }
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
