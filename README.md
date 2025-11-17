# ADBKernel

ADBKernel is a pure Swift implementation of the Android Debug Bridge (ADB) transport protocol. It opens a TCP connection
straight to the Android device (e.g. Android TV) and speaks the binary `adbd` protocol so you can send shell commands,
key events, and capture screenshots directly from SwiftUI applications running on iOS or macOS—no bundled `adb` binary is
required.

## Features

- Implements the ADB connection handshake (`CNXN`, `AUTH`, `OPEN`, `WRTE`, `CLSE`) entirely in Swift
- Works from iOS 15+/macOS 13+ without spawning subprocesses
- Provides a pluggable `ADBAuthenticator` so you can sign authentication tokens with your RSA keypair
- Supports optional TLS/SSL sockets with certificate pinning for the Android 11+ pairing flow
- Reuses sockets/ports (via `SO_REUSEADDR`/`SO_REUSEPORT`) and exposes a global connection pool
- Lets you open persistent `tcp:<port>` tunnels for low-level protocols
- Exposes convenience helpers for running shell commands, dispatching key events, and triggering `screencap`
- Implements the `sync:` service so you can `push`, `pull`, and `stat` files the same way libraries such as [adbutils](https://github.com/openatx/adbutils) do
- Ships with an async/await adapter so SwiftUI/iOS apps can await ADB operations without blocking the main thread

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

## TLS / SSL

Android 11+ introduced TLS-encrypted Wi‑Fi debugging. Enable it by switching the configuration to `.tls` and, optionally, pinning the server certificate:

```swift
let certificate = try Data(contentsOf: Bundle.main.url(forResource: "adb_pair_cert", withExtension: "der")!)
let tls = ADBKernel.TLSConfiguration(pinnedCertificates: [certificate])
let configuration = ADBKernel.Configuration(
    host: "192.168.1.120",
    port: 5555,
    transportSecurity: .tls(tls),
    authenticator: authenticator
)
let kernel = ADBKernel(configuration: configuration)
```

If you are pairing a brand-new device, set `allowUntrustedCertificates: true` temporarily so that the TLS handshake succeeds before the certificate has been stored, then tighten it back down with explicit pins.

## Socket and Port Reuse

`ADBKernel.Configuration` now exposes `socketOptions` and `allowsSocketReuse`:

```swift
let configuration = ADBKernel.Configuration(
    host: "192.168.1.120",
    allowsSocketReuse: true,
    socketOptions: .init(reuseAddress: true, reusePort: true)
)
```

With reuse enabled, completed connections are returned to a global pool so subsequent kernels (or reconnections) skip the TCP/TLS handshake entirely. Under the hood, the sockets are created with `SO_REUSEADDR`/`SO_REUSEPORT` so iOS can quickly recycle the local port.

## Persistent TCP Tunnels

Some device integrations (e.g. proprietary remote-control protocols) expect a long-lived `tcp:<port>` tunnel. Use `openTCPStream` to grab a duplex stream and reuse it:

```swift
let stream = try kernel.openTCPStream(toDevicePort: 6466)
try stream.send(Data([0x01, 0x02]))
if let response = try stream.receive() {
    print("Device replied: \(response as NSData)")
}
stream.close()
```

## File Transfers (Sync)

ADBKernel speaks the same `sync:` wire protocol that Google’s adb client and community projects such as `adbutils` expose. Use it
to move binaries, copy logs, or inspect metadata without shell round-trips:

```swift
let kernel = ADBKernel(host: "192.168.1.120")

let info = try kernel.stat("/sdcard/Download/video.mp4")
print("Size: \(info.size) bytes, permissions: \(String(info.permissions, radix: 8))")

let screenshot = try kernel.pullFile("/sdcard/Pictures/latest.png")
try screenshot.write(to: destinationURL)

let payload = try Data(contentsOf: localURL)
try kernel.pushFile(payload, to: "/sdcard/Download/app.bin", permissions: 0o755)
```

Under the hood the kernel opens the `sync:` service, issues `SEND`/`RECV`/`STAT` frames, and automatically chunks them to match
the payload size negotiated during the initial `CNXN` handshake so large transfers stream reliably.

## Swift Concurrency (async/await)

SwiftUI view models typically live on the main actor, so blocking ADB calls are not ideal. `ADBKernelAsyncAdapter` is an actor
that serializes all `ADBKernel` operations and surfaces async/await-friendly APIs so background work stays off the UI thread:

```swift
let adapter = ADBKernelAsyncAdapter(host: "192.168.1.120", authenticator: authenticator)

Task {
    do {
        try await adapter.connect()
        let screenshot = try await adapter.screenshot()
        try await adapter.pushFile(payload, to: "/sdcard/app.bin", permissions: 0o755)
    } catch {
        // update UI with the failure
    }
}
```

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
