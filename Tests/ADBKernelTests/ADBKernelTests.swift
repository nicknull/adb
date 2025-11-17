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

    func testPullFileUsesSyncService() throws {
        let server = MockADBServer { _ in Data() }
        let contents = Data("hello".utf8)
        server.seedSyncFile(path: "/sdcard/hello.txt", contents: contents, mode: 0o600, mtime: 321)
        let port = try server.start()
        defer { server.stop() }

        let kernel = ADBKernel(host: "127.0.0.1", port: port)
        let pulled = try kernel.pullFile("/sdcard/hello.txt")
        XCTAssertEqual(pulled, contents)
    }

    func testPushFilePersistsOnServer() throws {
        let server = MockADBServer { _ in Data() }
        let port = try server.start()
        defer { server.stop() }

        let kernel = ADBKernel(host: "127.0.0.1", port: port)
        let payload = Data("payload".utf8)
        let mtime = Date(timeIntervalSince1970: 77)
        try kernel.pushFile(payload, to: "/sdcard/payload.txt", permissions: 0o700, modifiedTime: mtime)
        let stored = server.syncFile(at: "/sdcard/payload.txt")
        XCTAssertEqual(stored?.data, payload)
        XCTAssertEqual(stored?.mode, 0o700)
        XCTAssertEqual(stored?.mtime, UInt32(mtime.timeIntervalSince1970))
    }

    func testStatReturnsMetadata() throws {
        let server = MockADBServer { _ in Data() }
        let data = Data("stat".utf8)
        let mtime: UInt32 = 1234
        server.seedSyncFile(path: "/sdcard/file.bin", contents: data, mode: 0o640, mtime: mtime)
        let port = try server.start()
        defer { server.stop() }

        let kernel = ADBKernel(host: "127.0.0.1", port: port)
        let info = try kernel.stat("/sdcard/file.bin")
        XCTAssertEqual(info.permissions, 0o640)
        XCTAssertEqual(info.size, UInt32(data.count))
        XCTAssertEqual(info.modifiedTime, Date(timeIntervalSince1970: TimeInterval(mtime)))
    }

    func testAsyncAdapterSupportsShellAndFileTransfers() throws {
        let stub = StubKernel()
        stub.shellResult = "shell:echo hi"
        let fileContents = Data("async".utf8)
        stub.pulls["/sdcard/async.txt"] = fileContents

        let adapter = ADBKernelAsyncAdapter(kernel: stub)
        let expectation = XCTestExpectation(description: "async adapter completes")

        Task.detached {
            do {
                try await adapter.connect()
                let output = try await adapter.shell("echo hi")
                XCTAssertEqual(output, "shell:echo hi")

                let pulled = try await adapter.pullFile("/sdcard/async.txt")
                XCTAssertEqual(pulled, fileContents)

                let payload = Data("payload".utf8)
                try await adapter.pushFile(payload, to: "/sdcard/upload.bin", permissions: 0o700)
                await adapter.disconnect()
            } catch {
                XCTFail("Async adapter failed: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(stub.connectCalls, 1)
        XCTAssertEqual(stub.disconnectCalls, 1)
        XCTAssertEqual(stub.shellCommands, ["echo hi"])
        XCTAssertEqual(stub.pushes.first?.path, "/sdcard/upload.bin")
        XCTAssertEqual(stub.pushes.first?.permissions, 0o700)
    }
}

private final class StubKernel: ADBKernelInterface {
    var connectCalls = 0
    var disconnectCalls = 0
    var shellCommands: [String] = []
    var shellResult = ""
    var pulls: [String: Data] = [:]
    var pushes: [(path: String, data: Data, permissions: UInt32)] = []

    func connect() throws {
        connectCalls += 1
    }

    func disconnect() {
        disconnectCalls += 1
    }

    func shell(_ command: String) throws -> String {
        shellCommands.append(command)
        return shellResult
    }

    func sendKeyEvent(_ keyCode: Int) throws {
        // Not used in stub
    }

    func screenshot() throws -> Data {
        return Data()
    }

    func screenshot(to destination: URL) throws {
        // Not used in stub
    }

    func pullFile(_ remotePath: String) throws -> Data {
        return pulls[remotePath] ?? Data()
    }

    func pullFile(_ remotePath: String, to destination: URL) throws {
        let data = try pullFile(remotePath)
        try data.write(to: destination)
    }

    func pushFile(
        _ data: Data,
        to remotePath: String,
        permissions: UInt32,
        modifiedTime: Date
    ) throws {
        pushes.append((remotePath, data, permissions))
    }

    func pushFile(
        from localURL: URL,
        to remotePath: String,
        permissions: UInt32,
        modifiedTime: Date
    ) throws {
        let data = try Data(contentsOf: localURL)
        try pushFile(data, to: remotePath, permissions: permissions, modifiedTime: modifiedTime)
    }

    func stat(_ remotePath: String) throws -> ADBKernel.FileInfo {
        return ADBKernel.FileInfo(path: remotePath, size: 0, permissions: 0, modifiedTime: .distantPast)
    }

    func openTCPStream(toDevicePort port: UInt16) throws -> ADBTCPStream {
        fatalError("Not implemented in stub")
    }
}
