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
}
