@testable import TetheringCore
import XCTest

final class IPv6Tests: XCTestCase {
    let hostMAC = MACAddress("02:00:00:aa:bb:cc")!
    let phoneMAC = MACAddress("02:00:00:11:22:33")!
    let phoneLinkLocal = IPv6Address("fe80::11:22ff:fe33:4455")!
    let prefix = IPv6Address("2001:db8:42:7::")!

    // MARK: Addresses

    func testParsingAndCanonicalFormatting() {
        XCTAssertEqual(IPv6Address("2001:0db8:0000:0000:0000:ff00:0042:8329")?.description, "2001:db8::ff00:42:8329")
        XCTAssertEqual(IPv6Address("::")?.description, "::")
        XCTAssertEqual(IPv6Address("::1")?.description, "::1")
        XCTAssertEqual(IPv6Address("fe80::")?.description, "fe80::")
        XCTAssertEqual(IPv6Address("2001:db8:0:1:1:1:1:1")?.description, "2001:db8:0:1:1:1:1:1", "single zero group is not compressed")
        XCTAssertEqual(IPv6Address("2001:0:0:1:0:0:0:1")?.description, "2001:0:0:1::1", "longest zero run wins")
        XCTAssertNil(IPv6Address("1::2::3"))
        XCTAssertNil(IPv6Address("12345::"))
        XCTAssertNil(IPv6Address("1:2:3"))
    }

    func testDerivedAddresses() {
        XCTAssertEqual(IPv6Address.linkLocal(eui64From: MACAddress("00:11:22:33:44:55")!).description,
                       "fe80::211:22ff:fe33:4455")
        let target = IPv6Address("2001:db8::1234:5678")!
        XCTAssertEqual(target.solicitedNodeMulticast.description, "ff02::1:ff34:5678")
        XCTAssertEqual(target.solicitedNodeMulticast.multicastMAC.description, "33:33:ff:34:56:78")
        XCTAssertTrue(target.hasPrefix(IPv6Address("2001:db8::")!, length: 64))
        XCTAssertFalse(target.hasPrefix(IPv6Address("2001:db9::")!, length: 32))
        XCTAssertTrue(IPv6Address("fe80::1")!.isLinkLocal)
        XCTAssertTrue(IPv6Address.allNodes.isMulticast)
    }

    // MARK: NDP wire format

    func testRouterAdvertisementRoundTripWithValidChecksum() throws {
        let ra = RouterAdvertisement(routerLifetime: 1800, sourceLinkLayer: phoneMAC,
                                     prefixes: [NDPPrefixInformation(prefix: prefix, prefixLength: 64,
                                                                     validLifetime: 3600, preferredLifetime: 1800)],
                                     mtu: 1500, dnsServers: [phoneLinkLocal])
        let message = NDPMessage.routerAdvertisement(ra)
        let bytes = message.icmpv6Message(source: phoneLinkLocal, destination: .allNodes)
        let packet = IPv6Packet(source: phoneLinkLocal, destination: .allNodes, nextHeader: 58, hopLimit: 255, payload: bytes)

        XCTAssertEqual(IPv6Packet.icmpv6Checksum(source: phoneLinkLocal, destination: .allNodes, message: bytes), 0)
        XCTAssertEqual(try NDPMessage(decodingICMPv6: bytes, verifyingWith: packet), message)

        var corrupted = [UInt8](bytes)
        corrupted[10] ^= 0xFF
        XCTAssertThrowsError(try NDPMessage(decodingICMPv6: Data(corrupted), verifyingWith: packet))
    }

    func testIPv6PacketRoundTrip() throws {
        let packet = IPv6Packet(source: phoneLinkLocal, destination: .allNodes, nextHeader: 17, payload: Data([1, 2, 3]))
        XCTAssertEqual(try IPv6Packet(decoding: packet.encoded()), packet)
        XCTAssertEqual(IPv6Packet.destination(of: packet.encoded()), .allNodes)
        XCTAssertEqual(IPVersion.of(packet.encoded()), 6)
    }

    // MARK: SLAAC

    func testSLAACSolicitsThenConfiguresFromAdvertisement() throws {
        let queue = DispatchQueue(label: "test.slaac")
        var sent: [Data] = []
        let interfaceID: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]
        let client = SLAACClient(mac: hostMAC, queue: queue, interfaceID: interfaceID, solicitationInterval: 60) {
            sent.append($0)
        }
        var configurations: [IPv6Configuration?] = []
        client.onConfigurationChange = { configurations.append($0) }

        queue.sync {
            client.start()
            client.handle(advertisement: self.advertisement(lifetime: 1800), from: self.phoneLinkLocal, sourceMAC: self.phoneMAC)
            client.handle(advertisement: self.advertisement(lifetime: 1800), from: self.phoneLinkLocal, sourceMAC: self.phoneMAC)
        }

        // Router Solicitation to ff02::2
        let rsFrame = try EthernetFrame(decoding: sent[0])
        XCTAssertEqual(rsFrame.destination.description, "33:33:00:00:00:02")
        let rsPacket = try IPv6Packet(decoding: rsFrame.payload)
        XCTAssertEqual(rsPacket.hopLimit, 255)
        XCTAssertEqual(try NDPMessage(decodingICMPv6: rsPacket.payload, verifyingWith: rsPacket),
                       .routerSolicitation(sourceLinkLayer: hostMAC))

        XCTAssertEqual(configurations.count, 1, "identical advertisements do not re-notify")
        let config = try XCTUnwrap(configurations.first ?? nil)
        XCTAssertEqual(config.address.description, "2001:db8:42:7:1020:3040:5060:7080")
        XCTAssertEqual(config.router, phoneLinkLocal)
        XCTAssertEqual(config.routerMAC, phoneMAC)
        XCTAssertEqual(config.dnsServers, [IPv6Address("2001:4860:4860::8888")!])
        XCTAssertTrue(config.isDefaultRouter)

        queue.sync {
            var withdrawn = self.advertisement(lifetime: 0)
            withdrawn.prefixes[0].validLifetime = 0
            client.handle(advertisement: withdrawn, from: self.phoneLinkLocal, sourceMAC: self.phoneMAC)
            client.stop()
        }
        XCTAssertEqual(configurations.count, 2)
        XCTAssertNil(configurations[1])
    }

    // MARK: Bridge

    func testBridgeAnswersNeighborSolicitationForHostAddress() throws {
        var toPhone: [Data] = []
        let bridge = PacketBridge(hostMAC: hostMAC, sendToPhone: { toPhone.append($0) }, deliverToHost: { _ in })
        let linkLocal = IPv6Address.linkLocal(eui64From: hostMAC)
        bridge.enableIPv6(linkLocal: linkLocal)

        let solicitation = NDPMessage.neighborSolicitation(target: linkLocal, sourceLinkLayer: phoneMAC)
            .frame(from: phoneMAC, to: linkLocal.solicitedNodeMulticast.multicastMAC,
                   source: phoneLinkLocal, destination: linkLocal.solicitedNodeMulticast)
        bridge.handleInbound(frame: try EthernetFrame(decoding: solicitation))

        let replyFrame = try EthernetFrame(decoding: try XCTUnwrap(toPhone.first))
        XCTAssertEqual(replyFrame.destination, phoneMAC)
        let replyPacket = try IPv6Packet(decoding: replyFrame.payload)
        XCTAssertEqual(replyPacket.destination, phoneLinkLocal)
        XCTAssertEqual(try NDPMessage(decodingICMPv6: replyPacket.payload, verifyingWith: replyPacket),
                       .neighborAdvertisement(target: linkLocal, router: false, solicited: true, override: true,
                                              targetLinkLayer: hostMAC))
    }

    func testBridgeRoutesOutboundIPv6ViaRouterAndDeliversInbound() throws {
        var toPhone: [EthernetFrame] = []
        var delivered: [Data] = []
        var advertisements = 0
        let bridge = PacketBridge(hostMAC: hostMAC, sendToPhone: { toPhone.append(try! EthernetFrame(decoding: $0)) },
                                  deliverToHost: { delivered.append($0) })
        bridge.enableIPv6(linkLocal: IPv6Address.linkLocal(eui64From: hostMAC))
        bridge.onRouterAdvertisement = { _, _, _ in advertisements += 1 }

        let hostAddress = IPv6Address(prefix: prefix, interfaceID: [0, 0, 0, 0, 0, 0, 0, 5])
        bridge.setIPv6(IPv6Configuration(address: hostAddress, prefix: prefix, prefixLength: 64,
                                         router: phoneLinkLocal, routerMAC: phoneMAC, dnsServers: [],
                                         mtu: nil, routerLifetime: 1800))

        // Off-link destination → router MAC (already known from the RA), no NS needed.
        let outbound = IPv6Packet(source: hostAddress, destination: IPv6Address("2606:4700::1111")!,
                                  nextHeader: 6, payload: Data([0])).encoded()
        bridge.handleOutbound(ipPacket: outbound)
        XCTAssertEqual(toPhone.last?.destination, phoneMAC)
        XCTAssertEqual(toPhone.last?.payload, outbound)

        // On-link, unknown neighbour → Neighbor Solicitation first.
        let neighbour = IPv6Address(prefix: prefix, interfaceID: [0, 0, 0, 0, 0, 0, 0, 9])
        bridge.handleOutbound(ipPacket: IPv6Packet(source: hostAddress, destination: neighbour, nextHeader: 6,
                                                   payload: Data([0])).encoded())
        XCTAssertEqual(toPhone.last?.destination, neighbour.solicitedNodeMulticast.multicastMAC)

        // Inbound traffic for the host is delivered; for others it is dropped.
        let inbound = IPv6Packet(source: IPv6Address("2606:4700::1111")!, destination: hostAddress,
                                 nextHeader: 6, payload: Data([0])).encoded()
        let foreign = IPv6Packet(source: IPv6Address("2606:4700::1111")!, destination: neighbour,
                                 nextHeader: 6, payload: Data([0])).encoded()
        bridge.handleInbound(frame: EthernetFrame(destination: hostMAC, source: phoneMAC, type: .ipv6, payload: inbound))
        bridge.handleInbound(frame: EthernetFrame(destination: hostMAC, source: phoneMAC, type: .ipv6, payload: foreign))
        XCTAssertEqual(delivered, [inbound])

        // Router Advertisements are terminated in the bridge and surfaced to the owner.
        let ra = NDPMessage.routerAdvertisement(advertisement(lifetime: 1800))
            .frame(from: phoneMAC, to: IPv6Address.allNodes.multicastMAC, source: phoneLinkLocal, destination: .allNodes)
        bridge.handleInbound(frame: try EthernetFrame(decoding: ra))
        XCTAssertEqual(advertisements, 1)
        XCTAssertEqual(delivered.count, 1)
    }

    // MARK: Helpers

    private func advertisement(lifetime: UInt16) -> RouterAdvertisement {
        RouterAdvertisement(routerLifetime: lifetime, sourceLinkLayer: phoneMAC,
                            prefixes: [NDPPrefixInformation(prefix: prefix, prefixLength: 64,
                                                            validLifetime: 7200, preferredLifetime: 3600)],
                            dnsServers: [IPv6Address("2001:4860:4860::8888")!])
    }
}
