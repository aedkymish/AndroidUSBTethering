import Foundation

/// EtherType values handled by the bridge.
public enum EtherType: UInt16 {
    case ipv4 = 0x0800
    case arp = 0x0806
    case ipv6 = 0x86DD
}

/// An Ethernet II frame (no FCS).
public struct EthernetFrame: Equatable {
    public static let headerLength = 14

    public var destination: MACAddress
    public var source: MACAddress
    public var etherType: UInt16
    public var payload: Data

    public init(destination: MACAddress, source: MACAddress, etherType: UInt16, payload: Data) {
        self.destination = destination
        self.source = source
        self.etherType = etherType
        self.payload = payload
    }

    public init(destination: MACAddress, source: MACAddress, type: EtherType, payload: Data) {
        self.init(destination: destination, source: source, etherType: type.rawValue, payload: payload)
    }

    public init(decoding data: Data) throws {
        let reader = ByteReader(data)
        try reader.require(Self.headerLength)
        guard let dst = MACAddress(try reader.slice(0, 6)),
              let src = MACAddress(try reader.slice(6, 6)) else {
            throw DecodingError.invalidValue("MAC address")
        }
        destination = dst
        source = src
        etherType = try reader.readBE(UInt16.self, at: 12)
        payload = Data(reader.bytes[Self.headerLength...])
    }

    public var type: EtherType? { EtherType(rawValue: etherType) }

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: Self.headerLength + payload.count)
        writer.write(destination.bytes)
        writer.write(source.bytes)
        writer.writeBE(etherType)
        writer.write(payload)
        return writer.data
    }
}
