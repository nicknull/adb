import Foundation

struct ADBPacket {
    let command: UInt32
    let arg0: UInt32
    let arg1: UInt32
    let data: Data

    init(command: UInt32, arg0: UInt32, arg1: UInt32, data: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.data = data
    }

    init?(from buffer: Data) {
        guard buffer.count >= 24 else { return nil }
        var cursor = buffer
        func readUInt32() -> UInt32 {
            let value = cursor.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            cursor.removeFirst(4)
            return value
        }
        let command = readUInt32()
        let arg0 = readUInt32()
        let arg1 = readUInt32()
        let length = readUInt32()
        let checksum = readUInt32()
        let magic = readUInt32()

        guard Int(length) <= cursor.count else { return nil }
        let payload = cursor.prefix(Int(length))
        let computedChecksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        guard checksum == computedChecksum else { return nil }
        guard magic == command ^ 0xFFFFFFFF else { return nil }
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.data = payload
    }

    func serialize() -> Data {
        var buffer = Data(capacity: 24 + data.count)
        var commandLE = command
        var arg0LE = arg0
        var arg1LE = arg1
        var length = UInt32(data.count)
        var checksum = data.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        var magic = command ^ 0xFFFFFFFF

        withUnsafeBytes(of: &commandLE) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: &arg0LE) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: &arg1LE) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: &checksum) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: &magic) { buffer.append(contentsOf: $0) }
        buffer.append(data)
        return buffer
    }
}

enum ADBCommand {
    static let cnxn: UInt32 = "CNXN".adbCommand
    static let auth: UInt32 = "AUTH".adbCommand
    static let open: UInt32 = "OPEN".adbCommand
    static let okay: UInt32 = "OKAY".adbCommand
    static let close: UInt32 = "CLSE".adbCommand
    static let write: UInt32 = "WRTE".adbCommand
}

enum ADBAuth {
    static let token: UInt32 = 1
    static let signature: UInt32 = 2
    static let publicKey: UInt32 = 3
}

private extension String {
    var adbCommand: UInt32 {
        var value: UInt32 = 0
        for (index, byte) in utf8.enumerated() {
            value |= UInt32(byte) << (index * 8)
        }
        return value
    }
}
