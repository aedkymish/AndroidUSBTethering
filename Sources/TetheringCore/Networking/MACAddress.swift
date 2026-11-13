import Foundation

/// A 48-bit IEEE 802 MAC address.
public struct MACAddress: Hashable, CustomStringConvertible, Codable {
    public let bytes: [UInt8]

    public static let broadcast = MACAddress(unchecked: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    public static let zero = MACAddress(unchecked: [0, 0, 0, 0, 0, 0])

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        bytes = parts
    }

    private init(unchecked bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var isBroadcast: Bool { self == .broadcast }
    public var isMulticast: Bool { bytes[0] & 0x01 != 0 }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
