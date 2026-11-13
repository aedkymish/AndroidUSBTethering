import Foundation

/// IPv6 counterpart of `ARPResolver`: keeps the neighbour cache, answers Neighbor Solicitations
/// for the host's addresses and queues outbound packets while a neighbour is being resolved.
public final class NeighborDiscovery {
    public static let maxPendingPerAddress = 32

    public let linkLocal: IPv6Address
    /// SLAAC global address, once configured.
    public var globalAddress: IPv6Address?
    public private(set) var table: [IPv6Address: MACAddress] = [:]

    private var pending: [IPv6Address: [Data]] = [:]
    private let hostMAC: MACAddress
    private let sendFrame: (Data) -> Void

    public init(hostMAC: MACAddress, linkLocal: IPv6Address, sendFrame: @escaping (Data) -> Void) {
        self.hostMAC = hostMAC
        self.linkLocal = linkLocal
        self.sendFrame = sendFrame
    }

    public func owns(_ address: IPv6Address) -> Bool {
        address == linkLocal || address == globalAddress
    }

    public func learn(_ ip: IPv6Address, _ mac: MACAddress) {
        guard !ip.isUnspecified, !ip.isMulticast, !mac.isMulticast else { return }
        table[ip] = mac
        for packet in pending.removeValue(forKey: ip) ?? [] {
            sendFrame(EthernetFrame(destination: mac, source: hostMAC, type: .ipv6, payload: packet).encoded())
        }
    }

    /// Sends `ipPacket` to `nextHop`, resolving its MAC first if needed.
    public func send(ipPacket: Data, to nextHop: IPv6Address) {
        if let mac = table[nextHop] {
            sendFrame(EthernetFrame(destination: mac, source: hostMAC, type: .ipv6, payload: ipPacket).encoded())
            return
        }
        var queue = pending[nextHop] ?? []
        let firstRequest = queue.isEmpty
        if queue.count < Self.maxPendingPerAddress { queue.append(ipPacket) }
        pending[nextHop] = queue
        if firstRequest { sendSolicitation(for: nextHop) }
    }

    public func sendSolicitation(for target: IPv6Address) {
        let source = (!target.isLinkLocal ? globalAddress : nil) ?? linkLocal
        let group = target.solicitedNodeMulticast
        sendFrame(NDPMessage.neighborSolicitation(target: target, sourceLinkLayer: hostMAC)
            .frame(from: hostMAC, to: group.multicastMAC, source: source, destination: group))
    }

    /// Processes an inbound NS / NA.
    public func handle(_ message: NDPMessage, in packet: IPv6Packet, frameSource: MACAddress) {
        switch message {
        case let .neighborSolicitation(target, sll):
            if !packet.source.isUnspecified { learn(packet.source, sll ?? frameSource) }
            guard owns(target) else { return }
            let unicast = !packet.source.isUnspecified
            let destination = unicast ? packet.source : IPv6Address.allNodes
            let reply = NDPMessage.neighborAdvertisement(target: target, router: false, solicited: unicast,
                                                         override: true, targetLinkLayer: hostMAC)
            sendFrame(reply.frame(from: hostMAC, to: unicast ? (sll ?? frameSource) : destination.multicastMAC,
                                  source: target, destination: destination))
        case let .neighborAdvertisement(target, _, _, _, tll):
            learn(target, tll ?? frameSource)
        case .routerSolicitation, .routerAdvertisement:
            break
        }
    }
}
