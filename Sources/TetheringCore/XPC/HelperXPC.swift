import Foundation

/// Identifiers shared by the app and the privileged helper.
public enum HelperConstants {
    public static let machServiceName = "com.aedkymish.AndroidUSBTethering.helper"
    public static let daemonPlistName = "com.aedkymish.AndroidUSBTethering.helper.plist"
    public static let appBundleIdentifier = "com.aedkymish.AndroidUSBTethering"
}

/// Snapshot of the helper's state, sent to the app as JSON over XPC.
public struct HelperStatus: Equatable, Codable {
    public var devices: [AndroidDevice]
    public var activeDeviceID: UInt64?
    public var state: TetheringState
    public var options: TetheringOptions
    public var autoConnect: Bool

    public init(devices: [AndroidDevice] = [], activeDeviceID: UInt64? = nil, state: TetheringState = .idle,
                options: TetheringOptions = TetheringOptions(), autoConnect: Bool = true) {
        self.devices = devices
        self.activeDeviceID = activeDeviceID
        self.state = state
        self.options = options
        self.autoConnect = autoConnect
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) throws -> HelperStatus {
        try JSONDecoder().decode(HelperStatus.self, from: data)
    }
}

/// XPC interface exported by the privileged helper. Payloads are JSON to keep the
/// Objective-C surface small and versionable.
@objc public protocol TetheringHelperProtocol {
    func fetchStatus(reply: @escaping (Data) -> Void)
    func connect(deviceID: UInt64, reply: @escaping (String?) -> Void)
    func disconnect(reply: @escaping () -> Void)
    /// `optionsJSON` is an encoded `TetheringOptions`.
    func update(optionsJSON: Data, autoConnect: Bool, reply: @escaping () -> Void)
    func helperVersion(reply: @escaping (String) -> Void)
}
