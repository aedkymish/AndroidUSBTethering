import Foundation

/// RFC 1071 Internet checksum.
public enum InternetChecksum {
    public static func compute(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }
}

/// Minimal IPv4 header view used for routing decisions and for building DHCP datagrams.
public struct IPv4Packet: Equatable {
    public static let protocolUDP: UInt8 = 17

    public var source: IPv4Address
    public var destination: IPv4Address
    public var protocolNumber: UInt8
    public var ttl: UInt8
    public var payload: Data

    public init(source: IPv4Address, destination: IPv4Address, protocolNumber: UInt8, ttl: UInt8 = 64, payload: Data) {
        self.source = source
        self.destination = destination
        self.protocolNumber = protocolNumber
        self.ttl = ttl
        self.payload = payload
    }

    public init(decoding data: Data) throws {
        let reader = ByteReader(data)
        try reader.require(20)
        let versionIHL = reader.bytes[0]
        guard versionIHL >> 4 == 4 else { throw DecodingError.invalidValue("IP version") }
        let headerLength = Int(versionIHL & 0x0F) * 4
        let totalLength = Int(try reader.readBE(UInt16.self, at: 2))
        guard headerLength >= 20, totalLength >= headerLength else {
            throw DecodingError.invalidValue("IPv4 lengths")
        }
        try reader.require(totalLength)
        ttl = reader.bytes[8]
        protocolNumber = reader.bytes[9]
        source = IPv4Address(rawValue: try reader.readBE(UInt32.self, at: 12))
        destination = IPv4Address(rawValue: try reader.readBE(UInt32.self, at: 16))
        payload = Data(reader.bytes[headerLength..<totalLength])
    }

    /// Reads only the destination address without validating the whole packet.
    public static func destination(of data: Data) -> IPv4Address? {
        guard data.count >= 20, data[data.startIndex] >> 4 == 4 else { return nil }
        let reader = ByteReader(data)
        return (try? reader.readBE(UInt32.self, at: 16)).map(IPv4Address.init(rawValue:))
    }

    public func encoded() -> Data {
        var header = ByteWriter(capacity: 20)
        header.write([0x45, 0x00])
        header.writeBE(UInt16(20 + payload.count))
        header.writeBE(UInt16(0))       // identification
        header.writeBE(UInt16(0x4000))  // don't fragment
        header.write([ttl, protocolNumber])
        header.writeBE(UInt16(0))       // checksum placeholder
        header.write(source.bytes)
        header.write(destination.bytes)
        var bytes = [UInt8](header.data)
        let checksum = InternetChecksum.compute(bytes)
        bytes[10] = UInt8(checksum >> 8)
        bytes[11] = UInt8(checksum & 0xFF)
        return Data(bytes) + payload
    }
}

/// UDP datagram (checksum is left as zero, which is legal for IPv4).
public struct UDPDatagram: Equatable {
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var payload: Data

    public init(sourcePort: UInt16, destinationPort: UInt16, payload: Data) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    public init(decoding data: Data) throws {
        let reader = ByteReader(data)
        try reader.require(8)
        sourcePort = try reader.readBE(UInt16.self, at: 0)
        destinationPort = try reader.readBE(UInt16.self, at: 2)
        let length = Int(try reader.readBE(UInt16.self, at: 4))
        guard length >= 8 else { throw DecodingError.invalidValue("UDP length") }
        try reader.require(length)
        payload = Data(reader.bytes[8..<length])
    }

    public func encoded() -> Data {
        var writer = ByteWriter(capacity: 8 + payload.count)
        writer.writeBE(sourcePort)
        writer.writeBE(destinationPort)
        writer.writeBE(UInt16(8 + payload.count))
        writer.writeBE(UInt16(0))
        writer.write(payload)
        return writer.data
    }
}
