import Foundation

public enum ADBError: Error, LocalizedError, Equatable {
    case notInstalled
    case unauthorized(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "adb was not found. Install Android platform-tools (brew install --cask android-platform-tools)."
        case let .unauthorized(name):
            return "Allow USB debugging for this Mac on \(name)."
        case let .commandFailed(output):
            return "adb failed: \(output)"
        }
    }
}

/// Finds the `adb` executable in the usual install locations.
public struct ADBLocator {
    private let candidates: [String]
    private let fileManager: FileManager

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory(), fileManager: FileManager = .default) {
        var paths: [String] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key] { paths.append(sdk + "/platform-tools/adb") }
        }
        paths += [
            home + "/Library/Android/sdk/platform-tools/adb", // Android Studio
            "/opt/homebrew/bin/adb",                          // Homebrew, Apple silicon
            "/usr/local/bin/adb",                             // Homebrew, Intel
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
        ]
        candidates = paths
        self.fileManager = fileManager
    }

    public func locate() -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

/// Turns USB tethering on and off through Android Debug Bridge.
///
/// Uses `svc usb setFunctions`, which the adb shell user may call on Android 9 and later.
/// USB debugging must be enabled on the phone and this Mac authorized. Runs in the user's
/// context (not the root helper) so the user's existing adb keys are used.
public final class ADBClient {
    public let executable: String?
    private let runner: CommandRunning

    public init(executable: String? = ADBLocator().locate(), runner: CommandRunning = ProcessCommandRunner()) {
        self.executable = executable
        self.runner = runner
    }

    public var isAvailable: Bool { executable != nil }

    public func devices() throws -> [ADBDevice] {
        ADBDevice.parseList(try adb(["devices", "-l"]))
    }

    /// Switches the phone's USB function to `function`, which starts USB tethering.
    public func enableTethering(on device: ADBDevice, function: ADBUSBFunction) throws {
        try requireAuthorized(device)
        try adb(["-s", device.serial, "shell", "svc", "usb", "setFunctions", function.rawValue])
    }

    /// Switches the phone back to charging only, which stops USB tethering.
    public func disableTethering(on device: ADBDevice) throws {
        try requireAuthorized(device)
        try adb(["-s", device.serial, "shell", "svc", "usb", "setFunctions"])
    }

    // MARK: Private

    private func requireAuthorized(_ device: ADBDevice) throws {
        guard device.state == .device else { throw ADBError.unauthorized(device.displayName) }
    }

    @discardableResult
    private func adb(_ arguments: [String]) throws -> String {
        guard let executable else { throw ADBError.notInstalled }
        do {
            let output = try runner.run(executable, arguments)
            // `adb shell` exits 0 even when the remote command fails; svc prints errors instead.
            let isShell = arguments.contains("shell")
            if isShell, output.localizedCaseInsensitiveContains("error") || output.contains("Exception") {
                throw ADBError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output
        } catch let error as CommandError {
            if case let .failed(_, _, output) = error {
                throw ADBError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw error
        }
    }
}

// ADBClient holds only immutable state (the executable path and the command runner), and each
// call starts its own process, so it can be used from any queue.
extension ADBClient: @unchecked Sendable {}
