import XCTest
@testable import ADBKernel

final class ADBKernelTests: XCTestCase {
    func testInjectDeviceAddsSelector() {
        let args = ADBKernel.injectDeviceID("DEVICE123", into: ["shell", "echo hello"])
        XCTAssertEqual(args, ["-s", "DEVICE123", "shell", "echo hello"])
    }

    func testSendKeyEventRoutesThroughShell() throws {
        let binaryURL = try TemporaryADBBinary.make()
        defer { try? FileManager.default.removeItem(at: binaryURL) }

        let kernel = try ADBKernel(adbPath: binaryURL.path, deviceID: "XYZ")
        let result = try kernel.sendKeyEvent(24)

        XCTAssertTrue(result.stdout.contains("shell"))
        XCTAssertTrue(result.stdout.contains("24"))
        XCTAssertEqual(result.stderr, "")
    }
}

private enum TemporaryADBBinary {
    static func make() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let script = """
        #!/bin/bash
        echo "$@"
        """
        try script.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([
            .posixPermissions: 0o755
        ], ofItemAtPath: fileURL.path)
        return fileURL
    }
}
