import Foundation

/// IPv6 fixed header plus payload (extension headers are carried opaquely in `payload`).
public struct IPv6Packet: Equatable {
    public static let headerLength = 40
    public static let nextHeaderICMPv6: UInt8 = 58

    public var source: IPv6Address
    public var destination: IPv6Address
    public var nextHeader: UInt8
    public var hopLimit: UInt8
    public var payload: Data

    public init(source: IPv6Address, destination: IPv6Address, nextHeader: UInt8, hopLimit: UInt8 = 64, payload: Data) {
        self.source = source
        self.destination = destination
        self.nextHeader = nextHeader
        self.hopLimit = hopLimit
        self.payload = payload
    }

    public init(decoding data: Data) throws {
        let r = ByteReader(data)
        try r.require(Self.headerLength)
        guard r.bytes[0] >> 4 == 6 else { throw DecodingError.invalidValue("IP version") }
        let payloadLength = Int(try r.readBE(UInt16.self, at: 4))
        try r.require(Self.headerLength + payloadLength)
        nextHeader = r.bytes[6]
        hopLimit = r.bytes[7]
        guard let src = IPv6Address(bytes: try r.slice(8, 16)),
              let dst = IPv6Address(bytes: try r.slice(24, 16)) else { throw DecodingError.invalidValue("address") }
        source = src
        destination = dst
        payload = Data(r.bytes[Self.headerLength..<(Self.headerLength + payloadLength)])
    }

    /// Reads only the destination address of an IPv6 packet.
    public static func destination(of data: Data) -> IPv6Address? {
        guard data.count >= headerLength, data[data.startIndex] >> 4 == 6 else { return nil }
        let start = data.startIndex + 24
        return IPv6Address(bytes: [UInt8](data[start..<(start + 16)]))
    }

    public func encoded() -> Data {
        var w = ByteWriter(capacity: Self.headerLength + payload.count)
        w.writeBE(UInt32(0x6000_0000)) // version 6, traffic class 0, flow label 0
        w.writeBE(UInt16(payload.count))
        w.write([nextHeader, hopLimit])
        w.write(source.bytes)
        w.write(destination.bytes)
        w.write(payload)
        return w.data
    }

    /// ICMPv6 checksum over the IPv6 pseudo-header and `message` (RFC 4443 §2.3).
    /// The message's checksum field must be zero when computing, or intact when verifying (result 0).
    public static func icmpv6Checksum(source: IPv6Address, destination: IPv6Address, message: Data) -> UInt16 {
        var w = ByteWriter(capacity: 40 + message.count)
        w.write(source.bytes)
        w.write(destination.bytes)
        w.writeBE(UInt32(message.count))
        w.write([0, 0, 0, nextHeaderICMPv6])
        w.write(message)
        return InternetChecksum.compute([UInt8](w.data))
    }
}

/// IP version of a raw packet (4, 6, or nil).
public enum IPVersion {
    public static func of(_ packet: Data) -> UInt8? {
        guard let first = packet.first else { return nil }
        let version = first >> 4
        return version == 4 || version == 6 ? version : nil
    }
}
