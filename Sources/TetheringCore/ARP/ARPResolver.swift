import Foundation

/// Keeps the IPv4 → MAC table for the tethering link, answers ARP requests for the
/// host address and queues outbound packets while a neighbour is being resolved.
public final class ARPResolver {
    public static let maxPendingPerAddress = 32

    public private(set) var table: [IPv4Address: MACAddress] = [:]
    private var pending: [IPv4Address: [Data]] = [:]
    private let hostMAC: MACAddress
    private let hostIP: IPv4Address
    private let sendFrame: (Data) -> Void

    public init(hostMAC: MACAddress, hostIP: IPv4Address, sendFrame: @escaping (Data) -> Void) {
        self.hostMAC = hostMAC
        self.hostIP = hostIP
        self.sendFrame = sendFrame
    }

    public func learn(_ ip: IPv4Address, _ mac: MACAddress) {
        guard ip != .any, !mac.isBroadcast, !mac.isMulticast else { return }
        table[ip] = mac
        for packet in pending.removeValue(forKey: ip) ?? [] {
            sendFrame(EthernetFrame(destination: mac, source: hostMAC, type: .ipv4, payload: packet).encoded())
        }
    }

    /// Sends `ipPacket` to `nextHop`, resolving its MAC first if needed.
    public func send(ipPacket: Data, to nextHop: IPv4Address) {
        if let mac = table[nextHop] {
            sendFrame(EthernetFrame(destination: mac, source: hostMAC, type: .ipv4, payload: ipPacket).encoded())
            return
        }
        var queue = pending[nextHop] ?? []
        let firstRequest = queue.isEmpty
        if queue.count < Self.maxPendingPerAddress { queue.append(ipPacket) }
        pending[nextHop] = queue
        if firstRequest { sendRequest(for: nextHop) }
    }

    public func sendRequest(for ip: IPv4Address) {
        let request = ARPPacket(operation: .request, senderMAC: hostMAC, senderIP: hostIP,
                                targetMAC: .zero, targetIP: ip)
        sendFrame(EthernetFrame(destination: .broadcast, source: hostMAC, type: .arp,
                                payload: request.encoded()).encoded())
    }

    /// Processes an inbound ARP packet: learns the sender and replies when asked for the host IP.
    public func handle(_ packet: ARPPacket) {
        learn(packet.senderIP, packet.senderMAC)
        guard packet.operation == .request, packet.targetIP == hostIP else { return }
        let reply = ARPPacket(operation: .reply, senderMAC: hostMAC, senderIP: hostIP,
                              targetMAC: packet.senderMAC, targetIP: packet.senderIP)
        sendFrame(EthernetFrame(destination: packet.senderMAC, source: hostMAC, type: .arp,
                                payload: reply.encoded()).encoded())
    }
}
