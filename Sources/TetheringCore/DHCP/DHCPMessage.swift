import Foundation

/// DHCP message types (option 53).
public enum DHCPMessageType: UInt8 {
    case discover = 1, offer, request, decline, ack, nak, release, inform
}

/// DHCP option codes used by the client.
public enum DHCPOptionCode {
    public static let pad: UInt8 = 0
    public static let subnetMask: UInt8 = 1
    public static let router: UInt8 = 3
    public static let dns: UInt8 = 6
    public static let hostName: UInt8 = 12
    public static let interfaceMTU: UInt8 = 26
    public static let requestedAddress: UInt8 = 50
    public static let leaseTime: UInt8 = 51
    public static let messageType: UInt8 = 53
    public static let serverIdentifier: UInt8 = 54
    public static let parameterRequestList: UInt8 = 55
    public static let clientIdentifier: UInt8 = 61
    public static let end: UInt8 = 255
}

/// A BOOTP/DHCP message (RFC 2131).
public struct DHCPMessage: Equatable {
    public static let magicCookie: UInt32 = 0x6382_5363
    public static let clientPort: UInt16 = 68
    public static let serverPort: UInt16 = 67
    static let fixedLength = 236

    public var op: UInt8                 // 1 = BOOTREQUEST, 2 = BOOTREPLY
    public var transactionID: UInt32
    public var flags: UInt16
    public var clientAddress: IPv4Address
    public var yourAddress: IPv4Address
    public var serverAddress: IPv4Address
    public var clientMAC: MACAddress
    /// Options in wire order, excluding pad/end.
    public var options: [(code: UInt8, value: [UInt8])]

    public init(op: UInt8, transactionID: UInt32, flags: UInt16 = 0x8000, clientAddress: IPv4Address = .any,
                yourAddress: IPv4Address = .any, serverAddress: IPv4Address = .any,
                clientMAC: MACAddress, options: [(code: UInt8, value: [UInt8])]) {
        self.op = op
        self.transactionID = transactionID
        self.flags = flags
        self.clientAddress = clientAddress
        self.yourAddress = yourAddress
        self.serverAddress = serverAddress
        self.clientMAC = clientMAC
        self.options = options
    }

    public static func == (lhs: DHCPMessage, rhs: DHCPMessage) -> Bool {
        lhs.encoded() == rhs.encoded()
    }

    public func option(_ code: UInt8) -> [UInt8]? {
        options.first { $0.code == code }?.value
    }

    public var messageType: DHCPMessageType? {
        option(DHCPOptionCode.messageType).flatMap { $0.first }.flatMap(DHCPMessageType.init(rawValue:))
    }

    public func addressOption(_ code: UInt8) -> IPv4Address? {
        option(code).flatMap { $0.count >= 4 ? IPv4Address(bytes: Array($0.prefix(4))) : nil }
    }

    public func addressListOption(_ code: UInt8) -> [IPv4Address] {
        guard let bytes = option(code) else { return [] }
        return stride(from: 0, to: bytes.count - 3, by: 4).compactMap { IPv4Address(bytes: Array(bytes[$0..<$0 + 4])) }
    }

    // MARK: Factories

    public static func discover(transactionID: UInt32, mac: MACAddress, hostName: String?) -> DHCPMessage {
        DHCPMessage(op: 1, transactionID: transactionID, clientMAC: mac,
                    options: commonOptions(.discover, mac: mac, hostName: hostName))
    }

    public static func request(transactionID: UInt32, mac: MACAddress, offered: IPv4Address,
                               server: IPv4Address, hostName: String?) -> DHCPMessage {
        var options = commonOptions(.request, mac: mac, hostName: hostName)
        options.append((DHCPOptionCode.requestedAddress, offered.bytes))
        options.append((DHCPOptionCode.serverIdentifier, server.bytes))
        return DHCPMessage(op: 1, transactionID: transactionID, clientMAC: mac, options: options)
    }

    /// RENEWING-state request: ciaddr is set, no requested-address / server-id options.
    public static func renew(transactionID: UInt32, mac: MACAddress, current: IPv4Address, hostName: String?) -> DHCPMessage {
        DHCPMessage(op: 1, transactionID: transactionID, clientAddress: current, clientMAC: mac,
                    options: commonOptions(.request, mac: mac, hostName: hostName))
    }

    public static func release(transactionID: UInt32, mac: MACAddress, current: IPv4Address, server: IPv4Address) -> DHCPMessage {
        DHCPMessage(op: 1, transactionID: transactionID, flags: 0, clientAddress: current, clientMAC: mac,
                    options: [(DHCPOptionCode.messageType, [DHCPMessageType.release.rawValue]),
                              (DHCPOptionCode.serverIdentifier, server.bytes)])
    }

    private static func commonOptions(_ type: DHCPMessageType, mac: MACAddress, hostName: String?) -> [(code: UInt8, value: [UInt8])] {
        var options: [(code: UInt8, value: [UInt8])] = [
            (DHCPOptionCode.messageType, [type.rawValue]),
            (DHCPOptionCode.clientIdentifier, [1] + mac.bytes),
            (DHCPOptionCode.parameterRequestList, [DHCPOptionCode.subnetMask, DHCPOptionCode.router,
                                                   DHCPOptionCode.dns, DHCPOptionCode.interfaceMTU,
                                                   DHCPOptionCode.leaseTime]),
        ]
        if let hostName, !hostName.isEmpty {
            options.append((DHCPOptionCode.hostName, Array(hostName.utf8.prefix(63))))
        }
        return options
    }

    // MARK: Wire format

    public func encoded() -> Data {
        var w = ByteWriter(capacity: 300)
        w.write([op, 1, 6, 0])            // op, htype=Ethernet, hlen=6, hops
        w.writeBE(transactionID)
        w.writeBE(UInt16(0))              // secs
        w.writeBE(flags)
        w.write(clientAddress.bytes)
        w.write(yourAddress.bytes)
        w.write(serverAddress.bytes)
        w.write(IPv4Address.any.bytes)    // giaddr
        w.write(clientMAC.bytes)
        w.writeZeros(10 + 64 + 128)       // chaddr padding, sname, file
        w.writeBE(Self.magicCookie)
        for option in options {
            w.write([option.code, UInt8(option.value.count)])
            w.write(option.value)
        }
        w.write([DHCPOptionCode.end])
        return w.data
    }

    public init(decoding data: Data) throws {
        let r = ByteReader(data)
        try r.require(Self.fixedLength + 4)
        guard try r.readBE(UInt32.self, at: Self.fixedLength) == Self.magicCookie else {
            throw DecodingError.invalidValue("DHCP magic cookie")
        }
        guard let mac = MACAddress(try r.slice(28, 6)) else { throw DecodingError.invalidValue("chaddr") }
        op = r.bytes[0]
        transactionID = try r.readBE(at: 4)
        flags = try r.readBE(at: 10)
        clientAddress = IPv4Address(rawValue: try r.readBE(at: 12))
        yourAddress = IPv4Address(rawValue: try r.readBE(at: 16))
        serverAddress = IPv4Address(rawValue: try r.readBE(at: 20))
        clientMAC = mac

        var parsed: [(code: UInt8, value: [UInt8])] = []
        var cursor = Self.fixedLength + 4
        while cursor < r.count {
            let code = r.bytes[cursor]
            if code == DHCPOptionCode.end { break }
            if code == DHCPOptionCode.pad { cursor += 1; continue }
            guard cursor + 1 < r.count else { break }
            let length = Int(r.bytes[cursor + 1])
            parsed.append((code, try r.slice(cursor + 2, length)))
            cursor += 2 + length
        }
        options = parsed
    }

    /// Builds the full Ethernet frame for a client-to-server broadcast.
    public func broadcastFrame(from mac: MACAddress, source: IPv4Address = .any) -> Data {
        let udp = UDPDatagram(sourcePort: Self.clientPort, destinationPort: Self.serverPort, payload: encoded())
        let ip = IPv4Packet(source: source, destination: .broadcast, protocolNumber: IPv4Packet.protocolUDP,
                            payload: udp.encoded())
        return EthernetFrame(destination: .broadcast, source: mac, type: .ipv4, payload: ip.encoded()).encoded()
    }

    /// Extracts a DHCP reply addressed to the client port from an Ethernet frame, if it is one.
    public static func reply(in frame: EthernetFrame) -> DHCPMessage? {
        guard frame.type == .ipv4,
              let ip = try? IPv4Packet(decoding: frame.payload), ip.protocolNumber == IPv4Packet.protocolUDP,
              let udp = try? UDPDatagram(decoding: ip.payload), udp.destinationPort == clientPort,
              let message = try? DHCPMessage(decoding: udp.payload), message.op == 2 else { return nil }
        return message
    }
}
