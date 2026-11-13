import Foundation

/// Translates between the layer-2 phone link (Ethernet frames) and the layer-3 host
/// interface (bare IPv4 packets). Must be used from a single queue.
public final class PacketBridge {
    private let hostMAC: MACAddress
    private let lease: DHCPLease
    private let arp: ARPResolver
    private let deliverToHost: (Data) -> Void

    public init(hostMAC: MACAddress, lease: DHCPLease,
                sendToPhone: @escaping (Data) -> Void, deliverToHost: @escaping (Data) -> Void) {
        self.hostMAC = hostMAC
        self.lease = lease
        self.deliverToHost = deliverToHost
        arp = ARPResolver(hostMAC: hostMAC, hostIP: lease.address, sendFrame: sendToPhone)
    }

    /// Learns the router MAC up front (it is the source of the DHCP ACK) to skip one ARP round-trip.
    public func prime(routerMAC: MACAddress) {
        arp.learn(lease.router, routerMAC)
    }

    /// Host → phone.
    public func handleOutbound(ipPacket: Data) {
        guard let destination = IPv4Packet.destination(of: ipPacket) else { return }
        let nextHop = destination.isInSameSubnet(as: lease.address, mask: lease.subnetMask) ? destination : lease.router
        arp.send(ipPacket: ipPacket, to: nextHop)
    }

    /// Phone → host.
    public func handleInbound(frame: EthernetFrame) {
        switch frame.type {
        case .arp?:
            if let packet = try? ARPPacket(decoding: frame.payload) { arp.handle(packet) }
        case .ipv4?:
            guard frame.destination == hostMAC || frame.destination.isBroadcast || frame.destination.isMulticast,
                  let destination = IPv4Packet.destination(of: frame.payload),
                  destination == lease.address || destination == .broadcast
                    || destination.rawValue == lease.address.rawValue | ~lease.subnetMask.rawValue
                    || destination.rawValue >> 28 == 0xE // multicast 224.0.0.0/4
            else { return }
            deliverToHost(frame.payload)
        default:
            break // IPv6 and other protocols are not bridged yet
        }
    }
}
