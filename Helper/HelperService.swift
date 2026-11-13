import Foundation
import IOKit
import os
import TetheringCore

/// XPC endpoint and coordinator for the privileged side.
/// Owns the device monitor and at most one active `TetheringSession`.
final class HelperService: NSObject, NSXPCListenerDelegate, TetheringHelperProtocol {
    static let version = "0.1.0"

    private let queue = DispatchQueue(label: "AndroidUSBTethering.helper")
    private let log = Logger(subsystem: HelperConstants.machServiceName, category: "helper")
    private let defaults = UserDefaults.standard
    private lazy var monitor = USBDeviceMonitor(queue: queue)
    private var session: TetheringSession?
    private var status = HelperStatus()

    private enum Keys {
        static let options = "TetheringOptions"
        static let autoConnect = "AutoConnect"
    }

    override init() {
        super.init()
        if let data = defaults.data(forKey: Keys.options),
           let options = try? JSONDecoder().decode(TetheringOptions.self, from: data) {
            status.options = options
        }
        if defaults.object(forKey: Keys.autoConnect) != nil {
            status.autoConnect = defaults.bool(forKey: Keys.autoConnect)
        }
    }

    func start() {
        queue.async {
            self.monitor.onAttach = { [weak self] device in self?.deviceAttached(device) }
            self.monitor.onDetach = { [weak self] id in self?.deviceDetached(id) }
            self.monitor.start()
        }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        #if !DEBUG
        // Only the signed app bundle may drive the helper.
        connection.setCodeSigningRequirement(
            "identifier \"\(HelperConstants.appBundleIdentifier)\" and anchor apple generic")
        #endif
        connection.exportedInterface = NSXPCInterface(with: TetheringHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: TetheringHelperProtocol

    func fetchStatus(reply: @escaping (Data) -> Void) {
        queue.async { reply(self.status.encoded()) }
    }

    func connect(deviceID: UInt64, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let device = self.status.devices.first(where: { $0.id == deviceID }) else {
                return reply("Device is no longer attached.")
            }
            reply(self.startSession(for: device))
        }
    }

    func disconnect(reply: @escaping () -> Void) {
        queue.async {
            self.stopSession()
            reply()
        }
    }

    func update(optionsJSON: Data, autoConnect: Bool, reply: @escaping () -> Void) {
        queue.async {
            if let options = try? JSONDecoder().decode(TetheringOptions.self, from: optionsJSON) {
                self.status.options = options
                self.defaults.set(optionsJSON, forKey: Keys.options)
            }
            self.status.autoConnect = autoConnect
            self.defaults.set(autoConnect, forKey: Keys.autoConnect)
            reply()
        }
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(Self.version)
    }

    // MARK: Device events (on queue)

    private func deviceAttached(_ device: AndroidDevice) {
        log.info("Attached: \(device.displayName, privacy: .public) [\(device.tetheringProtocol.rawValue, privacy: .public)]")
        status.devices.removeAll { $0.id == device.id }
        status.devices.append(device)
        switch device.tetheringProtocol {
        case .ncm:
            if session == nil { status.state = .nativeNCM(deviceName: device.name) }
        case .rndis:
            if status.autoConnect, session == nil { _ = startSession(for: device) }
        }
    }

    private func deviceDetached(_ id: UInt64) {
        log.info("Detached: \(id)")
        status.devices.removeAll { $0.id == id }
        if status.activeDeviceID == id {
            stopSession()
        } else if session == nil, case .nativeNCM = status.state {
            status.state = .idle
        }
    }

    // MARK: Session lifecycle (on queue)

    /// Returns an error message, or nil on success.
    private func startSession(for device: AndroidDevice) -> String? {
        guard device.tetheringProtocol == .rndis else {
            return "This phone uses NCM, which macOS handles natively."
        }
        stopSession()
        guard let service = monitor.service(for: device) else { return "Device is no longer attached." }
        defer { IOObjectRelease(service) }

        let channel: IOUSBHostChannel
        do {
            channel = try IOUSBHostChannel(controlService: service)
        } catch {
            log.error("USB open failed: \(error.localizedDescription, privacy: .public)")
            status.state = .failed(message: error.localizedDescription)
            return error.localizedDescription
        }
        let session = TetheringSession(device: device,
                                       transport: RNDISTransport(channel: channel),
                                       interface: UtunInterface(),
                                       options: status.options)
        session.onStateChange = { [weak self] state in
            self?.queue.async { self?.sessionStateChanged(state) }
        }
        self.session = session
        status.activeDeviceID = device.id
        session.start()
        return nil
    }

    private func stopSession() {
        session?.onStateChange = nil
        session?.stop()
        session = nil
        status.activeDeviceID = nil
        status.state = .idle
    }

    private func sessionStateChanged(_ state: TetheringState) {
        log.info("State: \(state.summary, privacy: .public)")
        guard session != nil else { return }
        status.state = state
        if case .failed = state {
            session = nil
            status.activeDeviceID = nil
        }
    }
}
