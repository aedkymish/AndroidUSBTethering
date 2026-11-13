import Foundation

/// Translates between the layer-2 phone link (Ethernet frames) and the layer-3 host
/// interface (bare IPv4 / IPv6 packets). Must be used from a single queue.
///
/// - IPv4 next hops are resolved with `ARPResolver`.
/// - IPv6 next hops are resolved with `NeighborDiscovery`; Router Advertisements are handed to
///   the owner through `onRouterAdvertisement` (for `SLAACClient`).
public final class PacketBridge {
    /// Called for every valid Router Advertisement: (advertisement, source address, source MAC).
    public var onRouterAdvertisement: ((RouterAdvertisement, IPv6Address, MACAddress) -> Void)?

    private let hostMAC: MACAddress
    private let sendToPhone: (Data) -> Void
    private let deliverToHost: (Data) -> Void

    private var lease: DHCPLease?
    private var arp: ARPResolver?
    private var ndp: NeighborDiscovery?
    private var ipv6: IPv6Configuration?

    public init(hostMAC: MACAddress, sendToPhone: @escaping (Data) -> Void, deliverToHost: @escaping (Data) -> Void) {
        self.hostMAC = hostMAC
        self.sendToPhone = sendToPhone
        self.deliverToHost = deliverToHost
    }

    /// Convenience initializer for an IPv4-enabled bridge.
    public convenience init(hostMAC: MACAddress, lease: DHCPLease,
                            sendToPhone: @escaping (Data) -> Void, deliverToHost: @escaping (Data) -> Void) {
        self.init(hostMAC: hostMAC, sendToPhone: sendToPhone, deliverToHost: deliverToHost)
        enableIPv4(lease: lease)
    }

    // MARK: Configuration

    public func enableIPv4(lease: DHCPLease) {
        self.lease = lease
        arp = ARPResolver(hostMAC: hostMAC, hostIP: lease.address, sendFrame: sendToPhone)
    }

    /// Learns the router MAC up front (it is the source of the DHCP ACK) to skip one ARP round-trip.
    public func prime(routerMAC: MACAddress) {
        if let lease { arp?.learn(lease.router, routerMAC) }
    }

    /// Starts answering Neighbor Discovery for `linkLocal` and accepting IPv6 traffic.
    public func enableIPv6(linkLocal: IPv6Address) {
        ndp = NeighborDiscovery(hostMAC: hostMAC, linkLocal: linkLocal, sendFrame: sendToPhone)
    }

    /// Sets (or clears) the SLAAC configuration used for IPv6 routing.
    public func setIPv6(_ configuration: IPv6Configuration?) {
        ipv6 = configuration
        ndp?.globalAddress = configuration?.address
        if let configuration, let mac = configuration.routerMAC {
            ndp?.learn(configuration.router, mac)
        }
    }

    // MARK: Host → phone

    public func handleOutbound(ipPacket: Data) {
        switch IPVersion.of(ipPacket) {
        case 4?: outboundIPv4(ipPacket)
        case 6?: outboundIPv6(ipPacket)
        default: break
        }
    }

    private func outboundIPv4(_ packet: Data) {
        guard let lease, let arp, let destination = IPv4Packet.destination(of: packet) else { return }
        let nextHop = destination.isInSameSubnet(as: lease.address, mask: lease.subnetMask) ? destination : lease.router
        arp.send(ipPacket: packet, to: nextHop)
    }

    private func outboundIPv6(_ packet: Data) {
        guard let ndp, let destination = IPv6Packet.destination(of: packet) else { return }
        if destination.isMulticast {
            sendToPhone(EthernetFrame(destination: destination.multicastMAC, source: hostMAC, type: .ipv6,
                                      payload: packet).encoded())
            return
        }
        let onLink = destination.isLinkLocal
            || ipv6.map { destination.hasPrefix($0.prefix, length: Int($0.prefixLength)) } == true
        if onLink {
            ndp.send(ipPacket: packet, to: destination)
        } else if let router = ipv6?.router {
            ndp.send(ipPacket: packet, to: router)
        }
    }

    // MARK: Phone → host

    public func handleInbound(frame: EthernetFrame) {
        switch frame.type {
        case .arp?:
            if let arp, let packet = try? ARPPacket(decoding: frame.payload) { arp.handle(packet) }
        case .ipv4?:
            inboundIPv4(frame)
        case .ipv6?:
            inboundIPv6(frame)
        default:
            break
        }
    }

    private func inboundIPv4(_ frame: EthernetFrame) {
        guard let lease,
              frame.destination == hostMAC || frame.destination.isBroadcast || frame.destination.isMulticast,
              let destination = IPv4Packet.destination(of: frame.payload),
              destination == lease.address || destination == .broadcast
                || destination.rawValue == lease.address.rawValue | ~lease.subnetMask.rawValue
                || destination.rawValue >> 28 == 0xE // multicast 224.0.0.0/4
        else { return }
        deliverToHost(frame.payload)
    }

    private func inboundIPv6(_ frame: EthernetFrame) {
        guard let ndp, frame.destination == hostMAC || frame.destination.isMulticast,
              let packet = try? IPv6Packet(decoding: frame.payload) else { return }

        if packet.nextHeader == IPv6Packet.nextHeaderICMPv6, let type = packet.payload.first,
           NDPMessage.isNDP(icmpType: type) {
            // Neighbor Discovery is terminated here, never forwarded to the host.
            guard packet.hopLimit == NDPMessage.hopLimit,
                  let message = try? NDPMessage(decodingICMPv6: packet.payload, verifyingWith: packet) else { return }
            if case let .routerAdvertisement(ra) = message {
                ndp.learn(packet.source, ra.sourceLinkLayer ?? frame.source)
                onRouterAdvertisement?(ra, packet.source, frame.source)
            } else {
                ndp.handle(message, in: packet, frameSource: frame.source)
            }
            return
        }

        let destination = packet.destination
        guard destination.isMulticast || ndp.owns(destination) else { return }
        deliverToHost(frame.payload)
    }
}
