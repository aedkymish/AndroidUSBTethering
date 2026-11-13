import Foundation

/// A 128-bit IPv6 address.
public struct IPv6Address: Hashable, CustomStringConvertible, Codable {
    public let bytes: [UInt8]

    public static let unspecified = IPv6Address(unchecked: [UInt8](repeating: 0, count: 16))
    /// ff02::1
    public static let allNodes = IPv6Address(unchecked: [0xFF, 0x02] + [UInt8](repeating: 0, count: 13) + [1])
    /// ff02::2
    public static let allRouters = IPv6Address(unchecked: [0xFF, 0x02] + [UInt8](repeating: 0, count: 13) + [2])

    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    private init(unchecked bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Parses the textual form, including `::` compression (embedded IPv4 is not supported).
    public init?(_ string: String) {
        let halves = string.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func groups(_ text: String) -> [UInt16]? {
            if text.isEmpty { return [] }
            var result: [UInt16] = []
            for part in text.split(separator: ":", omittingEmptySubsequences: false) {
                guard part.count <= 4, let value = UInt16(part, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }

        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 1 {
            guard head.count == 8 else { return nil }
            all = head
        } else {
            guard let tail = groups(halves[1]), head.count + tail.count <= 7 else { return nil }
            all = head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        bytes = all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    /// Joins the first 64 bits of `prefix` with a 64-bit interface identifier.
    public init(prefix: IPv6Address, interfaceID: [UInt8]) {
        precondition(interfaceID.count == 8)
        bytes = Array(prefix.bytes.prefix(8)) + interfaceID
    }

    /// fe80::/64 link-local address with a modified EUI-64 interface ID derived from `mac`.
    public static func linkLocal(eui64From mac: MACAddress) -> IPv6Address {
        let m = mac.bytes
        let interfaceID = [m[0] ^ 0x02, m[1], m[2], 0xFF, 0xFE, m[3], m[4], m[5]]
        return IPv6Address(prefix: IPv6Address(unchecked: [0xFE, 0x80] + [UInt8](repeating: 0, count: 14)),
                           interfaceID: interfaceID)
    }

    public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }
    public var isMulticast: Bool { bytes[0] == 0xFF }
    public var isLinkLocal: Bool { bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 }

    /// ff02::1:ffXX:XXXX for the last 24 bits of this address (RFC 4291 §2.7.1).
    public var solicitedNodeMulticast: IPv6Address {
        IPv6Address(unchecked: [0xFF, 0x02] + [UInt8](repeating: 0, count: 9) + [0x01, 0xFF] + Array(bytes[13...]))
    }

    /// Ethernet destination for an IPv6 multicast address: 33:33 + low 32 bits (RFC 2464 §7).
    public var multicastMAC: MACAddress {
        MACAddress([0x33, 0x33] + Array(bytes[12...]))!
    }

    public func hasPrefix(_ prefix: IPv6Address, length: Int) -> Bool {
        let fullBytes = length / 8
        guard bytes.prefix(fullBytes) == prefix.bytes.prefix(fullBytes) else { return false }
        let remainingBits = length % 8
        guard remainingBits > 0 else { return true }
        let mask = UInt8(0xFF) << (8 - remainingBits)
        return bytes[fullBytes] & mask == prefix.bytes[fullBytes] & mask
    }

    /// RFC 5952 canonical text form.
    public var description: String {
        let groups = (0..<8).map { UInt16(bytes[$0 * 2]) << 8 | UInt16(bytes[$0 * 2 + 1]) }
        var bestStart = -1, bestLength = 0, index = 0
        while index < 8 {
            guard groups[index] == 0 else { index += 1; continue }
            let start = index
            while index < 8, groups[index] == 0 { index += 1 }
            if index - start > bestLength { bestStart = start; bestLength = index - start }
        }
        let hex = groups.map { String($0, radix: 16) }
        guard bestLength >= 2 else { return hex.joined(separator: ":") }
        let head = hex[..<bestStart].joined(separator: ":")
        let tail = hex[(bestStart + bestLength)...].joined(separator: ":")
        return head + "::" + tail
    }
}
