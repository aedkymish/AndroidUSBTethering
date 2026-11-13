import Foundation
import SystemExtensions
import TetheringCore

/// Installation state of the DriverKit network driver.
enum DriverInstallState: Equatable {
    /// This build does not embed the driver (default build for free Apple IDs).
    case notBundled
    case unknown
    case notInstalled
    /// Waiting for the user to allow it in System Settings.
    case awaitingApproval
    case activating
    case activated
    /// macOS only activates system extensions from apps in /Applications.
    case requiresApplicationsFolder
    case failed(String)
}

/// Activates the AndroidRNDISDriver DriverKit extension embedded in the app
/// (Contents/Library/SystemExtensions) through the SystemExtensions framework.
/// Delegate callbacks arrive on the main queue; `onStateChange` is called there too.
final class DriverExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    var onStateChange: ((DriverInstallState) -> Void)?

    private let identifier = DriverKitDetector.driverBundleIdentifier

    /// Whether this app build embeds the driver extension (only the "DriverKit" build does).
    var isBundled: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).dext")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Queries the current state without changing anything.
    func refresh() {
        guard isBundled else { onStateChange?(.notBundled); return }
        submit(.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main))
    }

    func activate() {
        guard isBundled else { onStateChange?(.notBundled); return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            onStateChange?(.requiresApplicationsFolder)
            return
        }
        onStateChange?(.activating)
        submit(.activationRequest(forExtensionWithIdentifier: identifier, queue: .main))
    }

    func deactivate() {
        submit(.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStateChange?(.awaitingApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: onStateChange?(.activated)
        case .willCompleteAfterReboot: onStateChange?(.failed("Restart your Mac to finish installing the driver."))
        @unknown default: onStateChange?(.unknown)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let code = (error as NSError).code
        if code == OSSystemExtensionError.extensionNotFound.rawValue {
            onStateChange?(.notInstalled)
        } else {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let current = properties.first { !$0.isUninstalling }
        if current == nil {
            onStateChange?(.notInstalled)
        } else if current?.isAwaitingUserApproval == true {
            onStateChange?(.awaitingApproval)
        } else if current?.isEnabled == true {
            onStateChange?(.activated)
        } else {
            onStateChange?(.notInstalled)
        }
    }
}
