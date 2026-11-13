import Foundation
import TetheringCore

/// Installation state of the privileged helper.
enum HelperInstallState: Equatable {
    case unknown
    case notInstalled
    case requiresApproval
    case installed
    case failed(String)
}

/// Observable model for the UI (the "M" in MVC). Only the controller mutates it.
@MainActor
final class AppModel: ObservableObject {
    @Published var helperState: HelperInstallState = .unknown
    @Published var driverState: DriverInstallState = .unknown
    @Published var status = HelperStatus()
    @Published var helperReachable = false
    @Published var lastError: String?

    // ADB
    @Published var adbAvailable = false
    @Published var adbDevices: [ADBDevice] = []
    @Published var adbBusy = false

    /// Whether any tethering link (user-space, DriverKit or NCM) is up or coming up.
    var tetheringActive: Bool {
        switch status.state {
        case .nativeEthernet, .nativeNCM: return true
        default: return status.state.isActive
        }
    }

    var rndisDevices: [AndroidDevice] { status.devices.filter { $0.tetheringProtocol == .rndis } }

    var connectionInfo: ConnectionInfo? {
        if case let .connected(info) = status.state { return info }
        return nil
    }

    var nativeEthernet: (deviceName: String, interfaceName: String?)? {
        if case let .nativeEthernet(name, interface) = status.state { return (name, interface) }
        return nil
    }

    var menuBarSymbol: String {
        switch status.state {
        case .connected, .nativeEthernet: return "cable.connector"
        case .failed: return "exclamationmark.triangle"
        case .initializingLink, .negotiatingDHCP, .configuringNetwork: return "arrow.triangle.2.circlepath"
        case .idle, .nativeNCM: return "cable.connector.slash"
        }
    }
}
