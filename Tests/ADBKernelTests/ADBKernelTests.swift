import XCTest
@testable import ADBKernel

final class ADBKernelTests: XCTestCase {
    func testShellCommandReturnsPayload() throws {
        let server = MockADBServer { service in
            Data(service.utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let kernel = ADBKernel(host: "127.0.0.1", port: port)
        let output = try kernel.shell("echo hi")
        XCTAssertTrue(output.contains("shell:echo hi"))
    }

    func testKeyEventSendsInputCommand() throws {
        let expectation = XCTestExpectation(description: "key event sent")
        let server = MockADBServer { service in
            if service.contains("input keyevent 24") {
                expectation.fulfill()
            }
            return Data("ok".utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let kernel = ADBKernel(host: "127.0.0.1", port: port)
        try kernel.sendKeyEvent(24)
        wait(for: [expectation], timeout: 1.0)
    }

    func testConnectionRequiresAuthenticatorWhenAuthRequested() throws {
        let server = MockADBServer(authenticationMode: .signatureOnly) { _ in Data() }
        let port = try server.start()
        defer { server.stop() }

        let kernel = ADBKernel(host: "127.0.0.1", port: port)
        XCTAssertThrowsError(try kernel.connect())
    }

    func testAuthenticatorSendsSignatureThenPublicKey() throws {
        let server = MockADBServer(authenticationMode: .signatureThenPublicKey) { _ in Data() }
        let port = try server.start()
        defer { server.stop() }

        struct StubAuthenticator: ADBAuthenticator {
            func sign(authToken: Data) throws -> Data {
                return Data(repeating: 0xAB, count: authToken.count)
            }

            var publicKey: Data {
                var data = Data("stub-key".utf8)
                data.append(0)
                return data
            }
        }

        let configuration = ADBKernel.Configuration(host: "127.0.0.1", port: port, authenticator: StubAuthenticator())
        let kernel = ADBKernel(configuration: configuration)
        try kernel.connect()

        XCTAssertEqual(server.observedAuthTypes(), [ADBAuth.signature, ADBAuth.publicKey])
    }

    func testSocketReuseSharesUnderlyingConnection() throws {
        let server = MockADBServer { service in
            Data(service.utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let configuration = ADBKernel.Configuration(host: "127.0.0.1", port: port, allowsSocketReuse: true, reuseIdentifier: "pool-test")

        let firstKernel = ADBKernel(configuration: configuration)
        _ = try firstKernel.shell("echo one")
        firstKernel.disconnect()

        let secondKernel = ADBKernel(configuration: configuration)
        _ = try secondKernel.shell("echo two")
        secondKernel.disconnect()

        XCTAssertEqual(server.connectionsAccepted(), 1)
    }

    func testTCPStreamEchoesData() throws {
        let server = MockADBServer { _ in Data() }
        let port = try server.start()
        defer { server.stop() }

        let kernel = ADBKernel(host: "127.0.0.1", port: port)
        let stream = try kernel.openTCPStream(toDevicePort: 9000)
        let payload = Data("ping".utf8)
        try stream.send(payload)
        let echoed = try stream.receive()
        XCTAssertEqual(echoed, payload)
        stream.close()
    }
}
