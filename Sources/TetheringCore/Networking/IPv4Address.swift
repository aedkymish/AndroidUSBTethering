import Foundation

/// An IPv4 address stored in host byte order.
public struct IPv4Address: Hashable, Comparable, CustomStringConvertible, Codable {
    public let rawValue: UInt32

    public static let any = IPv4Address(rawValue: 0)
    public static let broadcast = IPv4Address(rawValue: 0xFFFF_FFFF)

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        rawValue = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        self.init(parts[0], parts[1], parts[2], parts[3])
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 else { return nil }
        self.init(bytes[0], bytes[1], bytes[2], bytes[3])
    }

    /// Network byte order representation.
    public var bytes: [UInt8] {
        [UInt8(rawValue >> 24 & 0xFF), UInt8(rawValue >> 16 & 0xFF),
         UInt8(rawValue >> 8 & 0xFF), UInt8(rawValue & 0xFF)]
    }

    public var description: String {
        bytes.map { String($0) }.joined(separator: ".")
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Returns `true` when both addresses fall inside the same subnet.
    public func isInSameSubnet(as other: IPv4Address, mask: IPv4Address) -> Bool {
        rawValue & mask.rawValue == other.rawValue & mask.rawValue
    }
}
