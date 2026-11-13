@testable import TetheringCore
import XCTest

final class BridgeTests: XCTestCase {
    let hostMAC = MACAddress("02:00:00:aa:bb:cc")!
    let phoneMAC = MACAddress("02:00:00:11:22:33")!
    lazy var lease = DHCPLease(address: IPv4Address(192, 168, 42, 50), subnetMask: IPv4Address(255, 255, 255, 0),
                               router: IPv4Address(192, 168, 42, 129), dnsServers: [],
                               serverIdentifier: IPv4Address(192, 168, 42, 129), leaseTime: 3600)

    func testOutboundPacketTriggersARPThenFlushesQueue() throws {
        var toPhone: [EthernetFrame] = []
        let bridge = PacketBridge(hostMAC: hostMAC, lease: lease,
                                  sendToPhone: { toPhone.append(try! EthernetFrame(decoding: $0)) },
                                  deliverToHost: { _ in })
        let packet = IPv4Packet(source: lease.address, destination: IPv4Address(8, 8, 8, 8),
                                protocolNumber: 17, payload: Data([1])).encoded()
        bridge.handleOutbound(ipPacket: packet)

        XCTAssertEqual(toPhone.count, 1)
        XCTAssertEqual(toPhone[0].type, .arp)
        let request = try ARPPacket(decoding: toPhone[0].payload)
        XCTAssertEqual(request.targetIP, lease.router)

        let reply = ARPPacket(operation: .reply, senderMAC: phoneMAC, senderIP: lease.router,
                              targetMAC: hostMAC, targetIP: lease.address)
        bridge.handleInbound(frame: EthernetFrame(destination: hostMAC, source: phoneMAC, type: .arp,
                                                  payload: reply.encoded()))
        XCTAssertEqual(toPhone.count, 2)
        XCTAssertEqual(toPhone[1].destination, phoneMAC)
        XCTAssertEqual(toPhone[1].payload, packet)
    }

    func testRepliesToARPRequestForHostAddress() throws {
        var toPhone: [EthernetFrame] = []
        let bridge = PacketBridge(hostMAC: hostMAC, lease: lease,
                                  sendToPhone: { toPhone.append(try! EthernetFrame(decoding: $0)) },
                                  deliverToHost: { _ in })
        let request = ARPPacket(operation: .request, senderMAC: phoneMAC, senderIP: lease.router,
                                targetMAC: .zero, targetIP: lease.address)
        bridge.handleInbound(frame: EthernetFrame(destination: .broadcast, source: phoneMAC, type: .arp,
                                                  payload: request.encoded()))
        let reply = try ARPPacket(decoding: toPhone[0].payload)
        XCTAssertEqual(reply.operation, .reply)
        XCTAssertEqual(reply.senderMAC, hostMAC)
        XCTAssertEqual(reply.targetMAC, phoneMAC)
    }

    func testInboundIPv4ForHostIsDeliveredAndOthersDropped() {
        var delivered: [Data] = []
        let bridge = PacketBridge(hostMAC: hostMAC, lease: lease, sendToPhone: { _ in },
                                  deliverToHost: { delivered.append($0) })
        let mine = IPv4Packet(source: IPv4Address(1, 1, 1, 1), destination: lease.address,
                              protocolNumber: 6, payload: Data([0])).encoded()
        let other = IPv4Packet(source: IPv4Address(1, 1, 1, 1), destination: IPv4Address(192, 168, 42, 77),
                               protocolNumber: 6, payload: Data([0])).encoded()
        bridge.handleInbound(frame: EthernetFrame(destination: hostMAC, source: phoneMAC, type: .ipv4, payload: mine))
        bridge.handleInbound(frame: EthernetFrame(destination: hostMAC, source: phoneMAC, type: .ipv4, payload: other))
        XCTAssertEqual(delivered, [mine])
    }
}
