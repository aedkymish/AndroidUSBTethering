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
    @Published var status = HelperStatus()
    @Published var helperReachable = false
    @Published var lastError: String?

    var rndisDevices: [AndroidDevice] { status.devices.filter { $0.tetheringProtocol == .rndis } }

    var connectionInfo: ConnectionInfo? {
        if case let .connected(info) = status.state { return info }
        return nil
    }

    var menuBarSymbol: String {
        switch status.state {
        case .connected: return "cable.connector"
        case .failed: return "exclamationmark.triangle"
        case .initializingLink, .negotiatingDHCP, .configuringNetwork: return "arrow.triangle.2.circlepath"
        case .idle, .nativeNCM: return "cable.connector.slash"
        }
    }
}
