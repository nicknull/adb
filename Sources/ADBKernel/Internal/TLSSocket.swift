#if canImport(Network)
import Foundation
import Network
import Security

final class TLSSocket: SocketConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "adbkernel.tls")

    init(host: String, port: UInt16, configuration: ADBKernel.Configuration.TLSConfiguration) throws {
        let tlsOptions = NWProtocolTLS.Options()
        if !configuration.pinnedCertificates.isEmpty {
            let pinned = configuration.pinnedCertificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            let tlsQueue = queue
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, secTrust, complete in
                guard let trust = secTrust else {
                    complete(errSecTrustNotAvailable)
                    return
                }
                let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
                let certificateCount = SecTrustGetCertificateCount(trustRef)
                var matched = false
                if certificateCount > 0, let certificate = SecTrustGetCertificateAtIndex(trustRef, 0) {
                    let data = SecCertificateCopyData(certificate) as Data
                    matched = pinned.contains(data)
                }
                if matched {
                    complete(errSecSuccess)
                } else {
                    complete(errSecTrustSettingDeny)
                }
            }, tlsQueue)
        } else if configuration.allowUntrustedCertificates {
            let tlsQueue = queue
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                complete(errSecSuccess)
            }, tlsQueue)
        }

        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SocketError.connectionFailed("Invalid port")
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        var startError: NWError?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startError = error
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        semaphore.wait()
        if let error = startError {
            throw SocketError.connectionFailed(error.localizedDescription)
        }
    }

    func send(_ data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: data, completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })
        semaphore.wait()
        if let error = sendError {
            throw SocketError.sendFailed
        }
    }

    func receive(length: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var receivedData = Data()
        var receiveError: NWError?
        connection.receive(minimumIncompleteLength: length, maximumLength: length, completion: { data, _, _, error in
            if let data {
                receivedData = data
            }
            receiveError = error
            semaphore.signal()
        })
        semaphore.wait()
        if let error = receiveError {
            throw SocketError.receiveFailed
        }
        return receivedData
    }

    func close() {
        connection.cancel()
    }
}
#endif
