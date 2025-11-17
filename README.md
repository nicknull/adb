# ADBKernel

ADBKernel is a pure Swift implementation of the Android Debug Bridge (ADB) transport protocol. It opens a TCP connection
straight to the Android device (e.g. Android TV) and speaks the binary `adbd` protocol so you can send shell commands,
key events, and capture screenshots directly from SwiftUI applications running on iOS or macOS—no bundled `adb` binary is
required.

## Features

- Implements the ADB connection handshake (`CNXN`, `AUTH`, `OPEN`, `WRTE`, `CLSE`) entirely in Swift
- Works from iOS 15+/macOS 13+ without spawning subprocesses
- Provides a pluggable `ADBAuthenticator` so you can sign authentication tokens with your RSA keypair
- Exposes convenience helpers for running shell commands, dispatching key events, and triggering `screencap`

## Usage

```swift
import ADBKernel

let kernel = ADBKernel(host: "192.168.1.120", port: 5555)
try kernel.connect()
try kernel.sendKeyEvent(26) // Power toggle
let screenshotData = try kernel.screenshot()
```

If your Android TV is secured (default on modern builds), provide an authenticator that can sign the token presented by
`adbd`:

```swift
#if canImport(Security)
let pem = try String(contentsOf: Bundle.main.url(forResource: "adb_private", withExtension: "pem")!)
let publicKey = try String(contentsOf: Bundle.main.url(forResource: "adbkey", withExtension: "pub")!)
let authenticator = try RSAPEMAuthenticator(pemPrivateKey: pem, adbPublicKey: publicKey)
let kernel = ADBKernel(host: "192.168.1.120", authenticator: authenticator)
#endif
```

The authenticator sends the same RSA assets that the classic `adb` client generates (`adbkey` and `adbkey.pub`). The device
first issues an `AUTH` token, which must be signed with your private key. If the key has not yet been authorized on that
device, it will ask for the public key payload contained inside `adbkey.pub` so the user can accept the fingerprint prompt on
the TV.

## iOS Deployment Notes

Because ADBKernel talks directly to the device, no helper executables are spawned. Your SwiftUI application simply opens a
TCP socket, performs the handshake, and issues commands. You still need to ship an RSA keypair that the device trusts. The
first time you connect, Android will display the RSA fingerprint and prompt you to authorize the key. Once accepted, future
connections succeed silently.

## Tests

Run the included test suite, which spins up a lightweight Swift mock of the ADB daemon, with:

```bash
swift test
```
