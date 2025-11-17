import Foundation

struct PoolKey: Hashable {
    let rawValue: String
}

final class ConnectionLease {
    let connection: ADBConnection
    private let key: PoolKey
    private weak var pool: ADBConnectionPool?
    private var released = false

    init(connection: ADBConnection, key: PoolKey, pool: ADBConnectionPool) {
        self.connection = connection
        self.key = key
        self.pool = pool
    }

    func release() {
        guard !released else { return }
        released = true
        pool?.recycle(connection: connection, key: key)
    }

    deinit {
        release()
    }
}

final class ADBConnectionPool {
    static let shared = ADBConnectionPool()

    private var storage: [PoolKey: [ADBConnection]] = [:]
    private let lock = NSLock()

    func acquire(for configuration: ADBKernel.Configuration) throws -> ConnectionLease {
        let key = configuration.poolKey()
        let connection: ADBConnection
        lock.lock()
        if var list = storage[key], !list.isEmpty {
            connection = list.removeLast()
            storage[key] = list.isEmpty ? nil : list
            lock.unlock()
        } else {
            lock.unlock()
            connection = try ADBConnection(configuration: configuration)
        }
        return ConnectionLease(connection: connection, key: key, pool: self)
    }

    fileprivate func recycle(connection: ADBConnection, key: PoolKey) {
        guard !connection.isClosed else { return }
        lock.lock()
        storage[key, default: []].append(connection)
        lock.unlock()
    }
}

extension ADBKernel.Configuration {
    fileprivate func poolKey() -> PoolKey {
        if let reuseIdentifier {
            return PoolKey(rawValue: reuseIdentifier)
        }
        let securityDescriptor = transportSecurity.descriptor
        let authenticatorIdentifier = authenticator.map { String(describing: type(of: $0)) } ?? "none"
        let identifier = "\(host):\(port):\(banner):\(securityDescriptor):\(authenticatorIdentifier)"
        return PoolKey(rawValue: identifier)
    }
}

extension ADBKernel.TransportSecurity {
    fileprivate var descriptor: String {
        switch self {
        case .plaintext:
            return "plain"
        case .tls(let config):
            return "tls-allowUnsafe:\(config.allowUntrustedCertificates)-pins:\(config.pinnedCertificates.count)"
        }
    }
}
