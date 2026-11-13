@testable import TetheringCore
import XCTest

final class DHCPTests: XCTestCase {
    let clientMAC = MACAddress("02:00:00:aa:bb:cc")!
    let phoneMAC = MACAddress("02:00:00:11:22:33")!
    let phoneIP = IPv4Address(192, 168, 42, 129)
    let offeredIP = IPv4Address(192, 168, 42, 50)

    func testDiscoverRoundTrip() throws {
        let discover = DHCPMessage.discover(transactionID: 0xDEADBEEF, mac: clientMAC, hostName: "mac")
        let decoded = try DHCPMessage(decoding: discover.encoded())
        XCTAssertEqual(decoded.messageType, .discover)
        XCTAssertEqual(decoded.transactionID, 0xDEADBEEF)
        XCTAssertEqual(decoded.clientMAC, clientMAC)
        XCTAssertEqual(decoded.option(DHCPOptionCode.hostName), Array("mac".utf8))
    }

    func testFullHandshakeProducesLease() throws {
        let queue = DispatchQueue(label: "test.dhcp")
        var sent: [Data] = []
        let client = DHCPClient(mac: clientMAC, hostName: nil, queue: queue, retryInterval: 60) { sent.append($0) }
        var result: Result<DHCPLease, Error>?

        queue.sync {
            client.start { result = $0 }
            let discover = try! self.dhcpMessage(in: sent[0])
            XCTAssertEqual(discover.messageType, .discover)

            client.handle(frame: self.serverReply(.offer, to: discover))
            XCTAssertEqual(client.phase, .requesting)
            let request = try! self.dhcpMessage(in: sent[1])
            XCTAssertEqual(request.messageType, .request)
            XCTAssertEqual(request.addressOption(DHCPOptionCode.requestedAddress), self.offeredIP)

            client.handle(frame: self.serverReply(.ack, to: request))
        }

        let lease = try XCTUnwrap(result).get()
        XCTAssertEqual(lease.address, offeredIP)
        XCTAssertEqual(lease.router, phoneIP)
        XCTAssertEqual(lease.dnsServers, [phoneIP])
        XCTAssertEqual(lease.leaseTime, 3600)
        XCTAssertEqual(client.phase, .bound)
        queue.sync { client.stop() }
    }

    func testNakFailsTheRequest() throws {
        let queue = DispatchQueue(label: "test.dhcp.nak")
        var sent: [Data] = []
        let client = DHCPClient(mac: clientMAC, hostName: nil, queue: queue, retryInterval: 60) { sent.append($0) }
        var result: Result<DHCPLease, Error>?
        queue.sync {
            client.start { result = $0 }
            client.handle(frame: self.serverReply(.offer, to: try! self.dhcpMessage(in: sent[0])))
            client.handle(frame: self.serverReply(.nak, to: try! self.dhcpMessage(in: sent[1])))
        }
        XCTAssertThrowsError(try XCTUnwrap(result).get()) { XCTAssertEqual($0 as? DHCPError, .declined) }
    }

    // MARK: Helpers

    private func dhcpMessage(in frameData: Data) throws -> DHCPMessage {
        let frame = try EthernetFrame(decoding: frameData)
        let ip = try IPv4Packet(decoding: frame.payload)
        let udp = try UDPDatagram(decoding: ip.payload)
        XCTAssertEqual(udp.destinationPort, DHCPMessage.serverPort)
        return try DHCPMessage(decoding: udp.payload)
    }

    private func serverReply(_ type: DHCPMessageType, to request: DHCPMessage) -> EthernetFrame {
        var leaseBytes = ByteWriter()
        leaseBytes.writeBE(UInt32(3600))
        let reply = DHCPMessage(op: 2, transactionID: request.transactionID, yourAddress: offeredIP,
                                clientMAC: clientMAC, options: [
                                    (DHCPOptionCode.messageType, [type.rawValue]),
                                    (DHCPOptionCode.serverIdentifier, phoneIP.bytes),
                                    (DHCPOptionCode.subnetMask, [255, 255, 255, 0]),
                                    (DHCPOptionCode.router, phoneIP.bytes),
                                    (DHCPOptionCode.dns, phoneIP.bytes),
                                    (DHCPOptionCode.leaseTime, [UInt8](leaseBytes.data)),
                                ])
        let udp = UDPDatagram(sourcePort: 67, destinationPort: 68, payload: reply.encoded())
        let ip = IPv4Packet(source: phoneIP, destination: .broadcast, protocolNumber: IPv4Packet.protocolUDP,
                            payload: udp.encoded())
        return EthernetFrame(destination: .broadcast, source: phoneMAC, type: .ipv4, payload: ip.encoded())
    }
}
