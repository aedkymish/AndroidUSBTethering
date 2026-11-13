import Foundation

/// An Ethernet/IPv4 ARP packet (RFC 826).
public struct ARPPacket: Equatable {
    public enum Operation: UInt16 { case request = 1, reply = 2 }

    public static let length = 28

    public var operation: Operation
    public var senderMAC: MACAddress
    public var senderIP: IPv4Address
    public var targetMAC: MACAddress
    public var targetIP: IPv4Address

    public init(operation: Operation, senderMAC: MACAddress, senderIP: IPv4Address,
                targetMAC: MACAddress, targetIP: IPv4Address) {
        self.operation = operation
        self.senderMAC = senderMAC
        self.senderIP = senderIP
        self.targetMAC = targetMAC
        self.targetIP = targetIP
    }

    public init(decoding data: Data) throws {
        let r = ByteReader(data)
        try r.require(Self.length)
        guard try r.readBE(UInt16.self, at: 0) == 1, try r.readBE(UInt16.self, at: 2) == EtherType.ipv4.rawValue,
              r.bytes[4] == 6, r.bytes[5] == 4 else {
            throw DecodingError.invalidValue("ARP hardware/protocol type")
        }
        guard let op = Operation(rawValue: try r.readBE(at: 6)),
              let sha = MACAddress(try r.slice(8, 6)),
              let tha = MACAddress(try r.slice(18, 6)) else {
            throw DecodingError.invalidValue("ARP fields")
        }
        operation = op
        senderMAC = sha
        senderIP = IPv4Address(rawValue: try r.readBE(at: 14))
        targetMAC = tha
        targetIP = IPv4Address(rawValue: try r.readBE(at: 24))
    }

    public func encoded() -> Data {
        var w = ByteWriter(capacity: Self.length)
        w.writeBE(UInt16(1))
        w.writeBE(EtherType.ipv4.rawValue)
        w.write([6, 4])
        w.writeBE(operation.rawValue)
        w.write(senderMAC.bytes)
        w.write(senderIP.bytes)
        w.write(targetMAC.bytes)
        w.write(targetIP.bytes)
        return w.data
    }
}
