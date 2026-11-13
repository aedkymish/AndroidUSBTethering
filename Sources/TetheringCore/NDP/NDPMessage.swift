import Foundation

/// Prefix Information option (RFC 4861 §4.6.2).
public struct NDPPrefixInformation: Equatable {
    public var prefix: IPv6Address
    public var prefixLength: UInt8
    public var onLink: Bool
    public var autonomous: Bool
    public var validLifetime: UInt32
    public var preferredLifetime: UInt32

    public init(prefix: IPv6Address, prefixLength: UInt8, onLink: Bool = true, autonomous: Bool = true,
                validLifetime: UInt32, preferredLifetime: UInt32) {
        self.prefix = prefix
        self.prefixLength = prefixLength
        self.onLink = onLink
        self.autonomous = autonomous
        self.validLifetime = validLifetime
        self.preferredLifetime = preferredLifetime
    }
}

/// Router Advertisement contents relevant to SLAAC.
public struct RouterAdvertisement: Equatable {
    public var hopLimit: UInt8
    public var managed: Bool
    public var otherConfig: Bool
    /// Seconds; 0 means "not a default router".
    public var routerLifetime: UInt16
    public var sourceLinkLayer: MACAddress?
    public var prefixes: [NDPPrefixInformation]
    public var mtu: UInt32?
    /// Recursive DNS servers (RFC 8106).
    public var dnsServers: [IPv6Address]

    public init(hopLimit: UInt8 = 64, managed: Bool = false, otherConfig: Bool = false, routerLifetime: UInt16,
                sourceLinkLayer: MACAddress? = nil, prefixes: [NDPPrefixInformation] = [], mtu: UInt32? = nil,
                dnsServers: [IPv6Address] = []) {
        self.hopLimit = hopLimit
        self.managed = managed
        self.otherConfig = otherConfig
        self.routerLifetime = routerLifetime
        self.sourceLinkLayer = sourceLinkLayer
        self.prefixes = prefixes
        self.mtu = mtu
        self.dnsServers = dnsServers
    }
}

/// ICMPv6 Neighbor Discovery messages (RFC 4861).
public enum NDPMessage: Equatable {
    case routerSolicitation(sourceLinkLayer: MACAddress?)
    case routerAdvertisement(RouterAdvertisement)
    case neighborSolicitation(target: IPv6Address, sourceLinkLayer: MACAddress?)
    case neighborAdvertisement(target: IPv6Address, router: Bool, solicited: Bool, override: Bool,
                               targetLinkLayer: MACAddress?)

    enum ICMPType {
        static let routerSolicitation: UInt8 = 133
        static let routerAdvertisement: UInt8 = 134
        static let neighborSolicitation: UInt8 = 135
        static let neighborAdvertisement: UInt8 = 136
        static let redirect: UInt8 = 137
        static let all: ClosedRange<UInt8> = 133...137
    }

    enum OptionType {
        static let sourceLinkLayer: UInt8 = 1
        static let targetLinkLayer: UInt8 = 2
        static let prefixInformation: UInt8 = 3
        static let mtu: UInt8 = 5
        static let rdnss: UInt8 = 25
    }

    /// NDP packets must be sent and received with hop limit 255 (RFC 4861 §6.1).
    public static let hopLimit: UInt8 = 255

    /// Returns `true` when an ICMPv6 payload is a Neighbor Discovery message.
    public static func isNDP(icmpType: UInt8) -> Bool { ICMPType.all.contains(icmpType) }

    // MARK: Encoding

    /// ICMPv6 message bytes with a valid checksum for the given addresses.
    public func icmpv6Message(source: IPv6Address, destination: IPv6Address) -> Data {
        var w = ByteWriter()
        switch self {
        case let .routerSolicitation(sll):
            w.write([ICMPType.routerSolicitation, 0, 0, 0])
            w.writeZeros(4)
            if let sll { Self.writeLinkLayer(&w, type: OptionType.sourceLinkLayer, sll) }
        case let .routerAdvertisement(ra):
            w.write([ICMPType.routerAdvertisement, 0, 0, 0, ra.hopLimit,
                     (ra.managed ? 0x80 : 0) | (ra.otherConfig ? 0x40 : 0)])
            w.writeBE(ra.routerLifetime)
            w.writeZeros(8) // reachable time, retrans timer
            if let sll = ra.sourceLinkLayer { Self.writeLinkLayer(&w, type: OptionType.sourceLinkLayer, sll) }
            if let mtu = ra.mtu {
                w.write([OptionType.mtu, 1, 0, 0])
                w.writeBE(mtu)
            }
            for info in ra.prefixes {
                w.write([OptionType.prefixInformation, 4, info.prefixLength,
                         (info.onLink ? 0x80 : 0) | (info.autonomous ? 0x40 : 0)])
                w.writeBE(info.validLifetime)
                w.writeBE(info.preferredLifetime)
                w.writeZeros(4)
                w.write(info.prefix.bytes)
            }
            if !ra.dnsServers.isEmpty {
                w.write([OptionType.rdnss, UInt8(1 + 2 * ra.dnsServers.count), 0, 0])
                w.writeBE(UInt32(ra.routerLifetime) * 3)
                ra.dnsServers.forEach { w.write($0.bytes) }
            }
        case let .neighborSolicitation(target, sll):
            w.write([ICMPType.neighborSolicitation, 0, 0, 0])
            w.writeZeros(4)
            w.write(target.bytes)
            if let sll { Self.writeLinkLayer(&w, type: OptionType.sourceLinkLayer, sll) }
        case let .neighborAdvertisement(target, router, solicited, override, tll):
            w.write([ICMPType.neighborAdvertisement, 0, 0, 0,
                     (router ? 0x80 : 0) | (solicited ? 0x40 : 0) | (override ? 0x20 : 0), 0, 0, 0])
            w.write(target.bytes)
            if let tll { Self.writeLinkLayer(&w, type: OptionType.targetLinkLayer, tll) }
        }
        var bytes = [UInt8](w.data)
        let checksum = IPv6Packet.icmpv6Checksum(source: source, destination: destination, message: Data(bytes))
        bytes[2] = UInt8(checksum >> 8)
        bytes[3] = UInt8(checksum & 0xFF)
        return Data(bytes)
    }

    /// Complete Ethernet frame carrying this message.
    public func frame(from mac: MACAddress, to destinationMAC: MACAddress,
                      source: IPv6Address, destination: IPv6Address) -> Data {
        let packet = IPv6Packet(source: source, destination: destination, nextHeader: IPv6Packet.nextHeaderICMPv6,
                                hopLimit: Self.hopLimit,
                                payload: icmpv6Message(source: source, destination: destination))
        return EthernetFrame(destination: destinationMAC, source: mac, type: .ipv6, payload: packet.encoded()).encoded()
    }

    private static func writeLinkLayer(_ w: inout ByteWriter, type: UInt8, _ mac: MACAddress) {
        w.write([type, 1])
        w.write(mac.bytes)
    }

    // MARK: Decoding

    /// Decodes an ICMPv6 NDP message. Pass the enclosing packet to verify its checksum.
    public init(decodingICMPv6 data: Data, verifyingWith packet: IPv6Packet? = nil) throws {
        let r = ByteReader(data)
        try r.require(8)
        if let packet, IPv6Packet.icmpv6Checksum(source: packet.source, destination: packet.destination,
                                                 message: data) != 0 {
            throw DecodingError.invalidValue("ICMPv6 checksum")
        }
        switch r.bytes[0] {
        case ICMPType.routerSolicitation:
            let options = try Self.options(r, from: 8)
            self = .routerSolicitation(sourceLinkLayer: Self.linkLayer(options, OptionType.sourceLinkLayer))
        case ICMPType.routerAdvertisement:
            try r.require(16)
            let options = try Self.options(r, from: 16)
            var ra = RouterAdvertisement(hopLimit: r.bytes[4], managed: r.bytes[5] & 0x80 != 0,
                                         otherConfig: r.bytes[5] & 0x40 != 0,
                                         routerLifetime: try r.readBE(at: 6),
                                         sourceLinkLayer: Self.linkLayer(options, OptionType.sourceLinkLayer))
            for (type, body) in options {
                let o = ByteReader(body)
                switch type {
                case OptionType.prefixInformation where body.count >= 30:
                    guard let prefix = IPv6Address(bytes: try o.slice(14, 16)) else { continue }
                    ra.prefixes.append(NDPPrefixInformation(
                        prefix: prefix, prefixLength: body[0], onLink: body[1] & 0x80 != 0,
                        autonomous: body[1] & 0x40 != 0, validLifetime: try o.readBE(at: 2),
                        preferredLifetime: try o.readBE(at: 6)))
                case OptionType.mtu where body.count >= 6:
                    ra.mtu = try o.readBE(at: 2)
                case OptionType.rdnss where body.count >= 22:
                    var offset = 6
                    while offset + 16 <= body.count {
                        if let server = IPv6Address(bytes: try o.slice(offset, 16)) { ra.dnsServers.append(server) }
                        offset += 16
                    }
                default:
                    break
                }
            }
            self = .routerAdvertisement(ra)
        case ICMPType.neighborSolicitation:
            try r.require(24)
            guard let target = IPv6Address(bytes: try r.slice(8, 16)) else { throw DecodingError.invalidValue("target") }
            let options = try Self.options(r, from: 24)
            self = .neighborSolicitation(target: target,
                                         sourceLinkLayer: Self.linkLayer(options, OptionType.sourceLinkLayer))
        case ICMPType.neighborAdvertisement:
            try r.require(24)
            guard let target = IPv6Address(bytes: try r.slice(8, 16)) else { throw DecodingError.invalidValue("target") }
            let options = try Self.options(r, from: 24)
            let flags = r.bytes[4]
            self = .neighborAdvertisement(target: target, router: flags & 0x80 != 0, solicited: flags & 0x40 != 0,
                                          override: flags & 0x20 != 0,
                                          targetLinkLayer: Self.linkLayer(options, OptionType.targetLinkLayer))
        default:
            throw DecodingError.invalidValue("ICMPv6 type \(r.bytes[0]) is not handled")
        }
    }

    /// Parses TLV options; each body excludes the 2-byte type/length header.
    private static func options(_ r: ByteReader, from start: Int) throws -> [(UInt8, [UInt8])] {
        var result: [(UInt8, [UInt8])] = []
        var cursor = start
        while cursor + 2 <= r.count {
            let length = Int(r.bytes[cursor + 1]) * 8
            guard length > 0 else { throw DecodingError.invalidValue("zero-length NDP option") }
            result.append((r.bytes[cursor], try r.slice(cursor + 2, length - 2)))
            cursor += length
        }
        return result
    }

    private static func linkLayer(_ options: [(UInt8, [UInt8])], _ type: UInt8) -> MACAddress? {
        options.first { $0.0 == type }.flatMap { MACAddress(Array($0.1.prefix(6))) }
    }
}
