import Foundation

/// Static information shown in the About window, read from the app bundle.
struct AboutInfo {
    static let repositoryURL = URL(string: "https://github.com/aedkymish/AndroidUSBTethering")!
    static let licenseURL = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    static let author = "Ali Edkymish"
    static let summary = "Use an Android phone's USB tethering on your Mac: RNDIS and NCM, IPv4 and IPv6, "
        + "with an optional DriverKit network driver and one-click tethering through ADB."

    let name: String
    let version: String
    let build: String
    let copyright: String
    /// Whether this build embeds the DriverKit driver.
    let includesDriverKit: Bool

    init(bundle: Bundle = .main, includesDriverKit: Bool) {
        name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Android USB Tethering"
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 \(Self.author)"
        self.includesDriverKit = includesDriverKit
    }

    var edition: String {
        includesDriverKit ? "DriverKit edition" : "Standard edition (user-space driver)"
    }
}

extension DriverInstallState {
    var summary: String {
        switch self {
        case .notBundled: return "Not included in this build"
        case .unknown: return "Unknown"
        case .notInstalled: return "Not installed"
        case .awaitingApproval: return "Waiting for approval"
        case .activating: return "Installing…"
        case .activated: return "Active"
        case .requiresApplicationsFolder: return "Move the app to /Applications"
        case let .failed(message): return "Error: \(message)"
        }
    }
}
