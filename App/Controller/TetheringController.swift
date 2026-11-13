import AppKit
import Foundation
import TetheringCore

/// Controller (the "C" in MVC): turns user intents into helper calls and keeps `AppModel` current.
@MainActor
final class TetheringController: ObservableObject {
    let model = AppModel()

    private let installer = HelperInstaller()
    private let driver = DriverExtensionManager()
    private let adb = ADBClient()
    private let adbQueue = DispatchQueue(label: "AndroidUSBTethering.adb")
    private var pollCount = 0

    nonisolated static let preferNCMKey = "ADBPreferNCM"
    /// How long to wait for an NCM interface before falling back to RNDIS.
    nonisolated static let ncmFallbackDelay = 10
    private let helper = HelperConnection()
    private var pollTask: Task<Void, Never>?
    static let pollInterval: Duration = .seconds(2)

    init() {
        model.helperState = installer.currentState()
        driver.onStateChange = { [weak self] state in
            Task { @MainActor in self?.model.driverState = state }
        }
        driver.refresh()
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

    func installDriver() {
        driver.activate()
    }

    func uninstallDriver() {
        driver.deactivate()
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

    // MARK: ADB

    func refreshADB() {
        model.adbAvailable = adb.isAvailable
        guard adb.isAvailable else {
            model.adbDevices = []
            return
        }
        Task {
            model.adbDevices = (try? await runADB { try $0.devices() }) ?? []
        }
    }

    /// Turns on USB tethering on the phone. Tries NCM first (if preferred), which macOS supports
    /// natively, and falls back to RNDIS when no NCM interface appears.
    func enableTethering(on device: ADBDevice) {
        model.adbBusy = true
        model.lastError = nil
        Task {
            do {
                if preferNCM {
                    try await runADB { try $0.enableTethering(on: device, function: .ncm) }
                    if await waitForNCMInterface() {
                        finishADBAction()
                        return
                    }
                }
                try await runADB { try $0.enableTethering(on: device, function: .rndis) }
            } catch {
                model.lastError = error.localizedDescription
            }
            finishADBAction()
        }
    }

    func disableTethering(on device: ADBDevice) {
        model.adbBusy = true
        model.lastError = nil
        Task {
            do {
                try await runADB { try $0.disableTethering(on: device) }
            } catch {
                model.lastError = error.localizedDescription
            }
            finishADBAction()
        }
    }

    private var preferNCM: Bool {
        UserDefaults.standard.object(forKey: Self.preferNCMKey) as? Bool ?? true
    }

    private func finishADBAction() {
        model.adbBusy = false
        refreshADB()
    }

    /// Waits for the helper to report an NCM interface. Without the helper there is nothing to
    /// observe, so NCM is assumed to work.
    private func waitForNCMInterface() async -> Bool {
        guard model.helperReachable else { return true }
        for _ in 0..<Self.ncmFallbackDelay {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
            if model.status.devices.contains(where: { $0.tetheringProtocol == .ncm }) { return true }
        }
        return false
    }

    /// Runs blocking adb commands off the main thread.
    private func runADB<T>(_ work: @escaping (ADBClient) throws -> T) async throws -> T {
        let adb = self.adb
        return try await withCheckedThrowingContinuation { continuation in
            adbQueue.async {
                continuation.resume(with: Result { try work(adb) })
            }
        }
    }

    // MARK: Settings

    func setEnableIPv6(_ value: Bool) {
        var options = model.status.options
        options.enableIPv6 = value
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
                await self?.pollADBPeriodically()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func pollADBPeriodically() {
        pollCount += 1
        if pollCount % 5 == 1 { refreshADB() } // every ~10 s
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
