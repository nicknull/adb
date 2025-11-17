import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TCPSocket: SocketConnection {
    private let fileDescriptor: Int32

    init(host: String, port: UInt16, options: ADBKernel.SocketOptions) throws {
        #if canImport(Darwin)
        typealias SocketAddr = sockaddr
        #endif

        #if canImport(Darwin)
        let socketType = Int32(SOCK_STREAM)
        let protocolType = Int32(IPPROTO_TCP)
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        let protocolType = Int32(IPPROTO_TCP)
        #endif

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: socketType,
            ai_protocol: protocolType,
            ai_addrlen: 0,
            ai_addr: nil,
            ai_canonname: nil,
            ai_next: nil
        )

        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let error = getaddrinfo(host, portString, &hints, &infoPointer)
        guard error == 0, let info = infoPointer else {
            throw SocketError.connectionFailed(String(cString: gai_strerror(error)))
        }

        var connectedFD: Int32 = -1
        var pointer = info
        while let address = pointer.pointee.ai_addr {
            let fd = socket(pointer.pointee.ai_family, pointer.pointee.ai_socktype, pointer.pointee.ai_protocol)
            if fd == -1 {
                pointer = pointer.pointee.ai_next
                continue
            }

            if options.reuseAddress {
                var value: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))
            }
            if options.reusePort {
                var value: Int32 = 1
#if canImport(Darwin)
                setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &value, socklen_t(MemoryLayout<Int32>.size))
#else
                setsockopt(fd, SOL_SOCKET, Int32(SO_REUSEPORT), &value, socklen_t(MemoryLayout<Int32>.size))
#endif
            }

            let result: Int32 = address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
#if canImport(Darwin)
                Darwin.connect(fd, $0, pointer.pointee.ai_addrlen)
#else
                Glibc.connect(fd, $0, pointer.pointee.ai_addrlen)
#endif
            }
            if result == 0 {
                connectedFD = fd
                break
            } else {
#if canImport(Darwin)
                Darwin.close(fd)
#else
                Glibc.close(fd)
#endif
            }
            guard let next = pointer.pointee.ai_next else { break }
            pointer = next
        }

        freeaddrinfo(info)

        if connectedFD == -1 {
            throw SocketError.connectionFailed("Unable to connect to host")
        }

        self.fileDescriptor = connectedFD
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress else { return }
            var bytesRemaining = buffer.count
            var totalSent = 0
            while bytesRemaining > 0 {
#if canImport(Darwin)
                let sent = Darwin.send(fileDescriptor, baseAddress.advanced(by: totalSent), bytesRemaining, 0)
#else
                let sent = Glibc.send(fileDescriptor, baseAddress.advanced(by: totalSent), bytesRemaining, 0)
#endif
                if sent <= 0 {
                    throw SocketError.sendFailed
                }
                totalSent += sent
                bytesRemaining -= sent
            }
        }
    }

    func receive(length: Int) throws -> Data {
        var buffer = Data(count: length)
        var bytesRead = 0
        try buffer.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
            while bytesRead < length {
#if canImport(Darwin)
                let result = Darwin.recv(fileDescriptor, rawBuffer.baseAddress!.advanced(by: bytesRead), length - bytesRead, 0)
#else
                let result = Glibc.recv(fileDescriptor, rawBuffer.baseAddress!.advanced(by: bytesRead), length - bytesRead, 0)
#endif
                if result <= 0 {
                    throw SocketError.receiveFailed
                }
                bytesRead += result
            }
        }
        return buffer
    }

    func close() {
#if canImport(Darwin)
        Darwin.close(fileDescriptor)
#else
        Glibc.close(fileDescriptor)
#endif
    }
}
