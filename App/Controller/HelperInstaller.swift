import Foundation
import ServiceManagement
import TetheringCore

/// Registers the launchd daemon bundled inside the app (Contents/Library/LaunchDaemons).
struct HelperInstaller {
    private var service: SMAppService { .daemon(plistName: HelperConstants.daemonPlistName) }

    func currentState() -> HelperInstallState {
        switch service.status {
        case .enabled: return .installed
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notInstalled
        @unknown default: return .unknown
        }
    }

    func install() -> HelperInstallState {
        do {
            try service.register()
        } catch {
            let state = currentState()
            return state == .requiresApproval ? state : .failed(error.localizedDescription)
        }
        return currentState()
    }

    func uninstall() throws {
        try service.unregister()
    }

    /// Terminal command that installs the helper without SMAppService (see install-helper.sh).
    var manualInstallCommand: String {
        let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Scripts/install-helper.sh").path
        return "sudo sh \"\(script)\""
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
