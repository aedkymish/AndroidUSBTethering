import AppKit
import Foundation
import TetheringCore

/// Controller (the "C" in MVC): turns user intents into helper calls and keeps `AppModel` current.
@MainActor
final class TetheringController: ObservableObject {
    let model = AppModel()

    private let installer = HelperInstaller()
    private let helper = HelperConnection()
    private var pollTask: Task<Void, Never>?
    static let pollInterval: Duration = .seconds(2)

    init() {
        model.helperState = installer.currentState()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: User intents

    func installHelper() {
        model.helperState = installer.install()
        if model.helperState == .requiresApproval {
            installer.openApprovalSettings()
        }
    }

    func openApprovalSettings() {
        installer.openApprovalSettings()
    }

    func connect(_ device: AndroidDevice) {
        Task {
            do {
                model.lastError = try await helper.connect(deviceID: device.id)
            } catch {
                model.lastError = error.localizedDescription
            }
            await refresh()
        }
    }

    func disconnect() {
        Task {
            do {
                try await helper.disconnect()
            } catch {
                model.lastError = error.localizedDescription
            }
            await refresh()
        }
    }

    func setRouteAllTraffic(_ value: Bool) {
        var options = model.status.options
        options.routeAllTraffic = value
        apply(options: options, autoConnect: model.status.autoConnect)
    }

    func setUsePhoneDNS(_ value: Bool) {
        var options = model.status.options
        options.usePhoneDNS = value
        apply(options: options, autoConnect: model.status.autoConnect)
    }

    func setAutoConnect(_ value: Bool) {
        apply(options: model.status.options, autoConnect: value)
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Private

    private func apply(options: TetheringOptions, autoConnect: Bool) {
        model.status.options = options
        model.status.autoConnect = autoConnect
        Task {
            do {
                try await helper.update(options: options, autoConnect: autoConnect)
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func refresh() async {
        model.helperState = installer.currentState()
        guard model.helperState == .installed else {
            model.helperReachable = false
            return
        }
        do {
            model.status = try await helper.fetchStatus()
            model.helperReachable = true
        } catch {
            model.helperReachable = false
            helper.invalidate()
        }
    }
}
