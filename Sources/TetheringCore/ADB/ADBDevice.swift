import Foundation

/// A phone listed by `adb devices -l`.
public struct ADBDevice: Equatable, Hashable, Identifiable, Codable {
    public enum State: String, Codable {
        /// Connected and authorized; commands can run.
        case device
        /// USB debugging is not yet allowed for this Mac on the phone.
        case unauthorized
        case offline
        case other
    }

    public var id: String { serial }
    public let serial: String
    public let state: State
    public let model: String?
    public let product: String?

    public init(serial: String, state: State, model: String? = nil, product: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
    }

    public var displayName: String { model ?? product ?? serial }

    /// Parses the output of `adb devices -l`.
    public static func parseList(_ output: String) -> [ADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> ADBDevice? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            var attributes: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { attributes[parts[0]] = parts[1] }
            }
            return ADBDevice(serial: fields[0],
                             state: State(rawValue: fields[1]) ?? .other,
                             model: attributes["model"]?.replacingOccurrences(of: "_", with: " "),
                             product: attributes["product"])
        }
    }
}

/// USB function to request from the phone.
public enum ADBUSBFunction: String, Codable, CaseIterable {
    /// Microsoft RNDIS: supported by every Android phone; needs this app's driver on macOS.
    case rndis
    /// CDC-NCM: driven natively by macOS; available on many Android 11+ phones.
    case ncm
}
