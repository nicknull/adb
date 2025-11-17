# ADBKernel

A lightweight Swift Package that exposes a small "ADB kernel" which you can embed inside a SwiftUI app to talk to Android TV devices. The kernel relies on the Android Debug Bridge (ADB) binary that is distributed with the Android SDK and shells out to it using `Process`.

## Features

- Automatically resolves the `adb` binary with `which` or accepts a custom path
- Handles `adb start-server`, `connect`, `disconnect`, `shell`, `install`, `pull`, and basic key events
- Throws strongly typed `KernelError` values you can surface in your UI
- Designed to be run from a SwiftUI app (macOS/iOS) that needs to automate an Android TV over TCP/IP

## Usage

Add the package to your `Package.swift` dependencies and import `ADBKernel`.

```swift
import ADBKernel

let kernel = try ADBKernel(deviceID: "192.168.1.43:5555")
try kernel.startServer()
try kernel.connect("192.168.1.43:5555")
try kernel.sendKeyEvent(26) // Power toggle
```

You can embed the commands inside a SwiftUI `ObservableObject` to update the UI when an action succeeds or fails.

```swift
@MainActor
final class AndroidRemoteViewModel: ObservableObject {
    private let kernel = try? ADBKernel(deviceID: "192.168.1.43:5555")

    func volumeUp() {
        Task {
            do {
                try kernel?.sendKeyEvent(24)
            } catch {
                // Update published error state
            }
        }
    }
}
```

## Running on iOS

The package now declares iOS 15.0+ as a supported platform so it can be consumed by a SwiftUI application that targets iPhone
or iPad hardware. Because iOS apps cannot rely on the host environment having `adb` installed, bundle a copy of the `adb`
binary inside your application (for internal/test builds) and resolve it with `Bundle.main.url(forResource:withExtension:)`
when creating the kernel:

```swift
let adbURL = Bundle.main.url(forResource: "adb", withExtension: nil)!
let kernel = try ADBKernel(adbPath: adbURL.path, deviceID: "192.168.1.43:5555")
```

> **Note:** Executing bundled binaries is only permitted for internal enterprise/test deployments. Apps submitted to the App
Store will be rejected if they launch helper executables, so prefer Mac Catalyst or macOS targets when distributing to the
public.

## Tests

The package ships with unit tests that stub the `adb` binary, proving that command arguments (device selection, key events, etc.) are wired correctly. Run them with:

```bash
swift test
```
