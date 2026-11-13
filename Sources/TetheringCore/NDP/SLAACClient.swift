import Foundation

/// IPv6 settings learned from the phone's Router Advertisements.
public struct IPv6Configuration: Equatable, Codable {
    public var address: IPv6Address
    public var prefix: IPv6Address
    public var prefixLength: UInt8
    /// The phone's link-local address (next hop for off-link traffic).
    public var router: IPv6Address
    public var routerMAC: MACAddress?
    public var dnsServers: [IPv6Address]
    public var mtu: UInt32?
    public var routerLifetime: UInt16

    public init(address: IPv6Address, prefix: IPv6Address, prefixLength: UInt8, router: IPv6Address,
                routerMAC: MACAddress?, dnsServers: [IPv6Address], mtu: UInt32?, routerLifetime: UInt16) {
        self.address = address
        self.prefix = prefix
        self.prefixLength = prefixLength
        self.router = router
        self.routerMAC = routerMAC
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.routerLifetime = routerLifetime
    }

    /// Whether the phone offers itself as an IPv6 default router.
    public var isDefaultRouter: Bool { routerLifetime > 0 }
}

/// Stateless address autoconfiguration (RFC 4862): sends Router Solicitations, turns the
/// phone's Router Advertisement into an `IPv6Configuration`, and expires it when its lifetime ends.
/// Android tethering advertises a /64 with RDNSS; it does not run DHCPv6.
/// All methods must be called on `queue`.
public final class SLAACClient {
    public let linkLocal: IPv6Address
    public private(set) var configuration: IPv6Configuration?
    /// Called on the queue when the configuration appears, changes or is withdrawn (`nil`).
    public var onConfigurationChange: ((IPv6Configuration?) -> Void)?

    private let mac: MACAddress
    private let interfaceID: [UInt8]
    private let queue: DispatchQueue
    private let sendFrame: (Data) -> Void
    private let solicitationInterval: TimeInterval
    private let maxSolicitations: Int
    private var solicitationsSent = 0
    private var solicitTimer: DispatchWorkItem?
    private var expiryTimer: DispatchWorkItem?

    /// - Parameter interfaceID: 64-bit identifier for the global address. Defaults to a random
    ///   value per session (privacy addressing, RFC 8981 style) rather than one derived from the MAC.
    public init(mac: MACAddress, queue: DispatchQueue, interfaceID: [UInt8]? = nil,
                solicitationInterval: TimeInterval = 4, maxSolicitations: Int = 3,
                sendFrame: @escaping (Data) -> Void) {
        self.mac = mac
        self.queue = queue
        self.sendFrame = sendFrame
        self.solicitationInterval = solicitationInterval
        self.maxSolicitations = maxSolicitations
        linkLocal = IPv6Address.linkLocal(eui64From: mac)
        if let interfaceID, interfaceID.count == 8 {
            self.interfaceID = interfaceID
        } else {
            var random = (0..<8).map { _ in UInt8.random(in: 0...255) }
            random[0] &= ~0x02 // locally generated, not EUI-64 derived
            self.interfaceID = random
        }
    }

    public func start() {
        solicitationsSent = 0
        solicit()
    }

    public func stop() {
        solicitTimer?.cancel()
        expiryTimer?.cancel()
        solicitTimer = nil
        expiryTimer = nil
        configuration = nil
    }

    /// Applies a Router Advertisement received from `source` (the phone's link-local address).
    public func handle(advertisement ra: RouterAdvertisement, from source: IPv6Address, sourceMAC: MACAddress) {
        solicitTimer?.cancel()
        solicitTimer = nil

        guard source.isLinkLocal,
              let info = ra.prefixes.first(where: { $0.autonomous && $0.prefixLength == 64 && $0.validLifetime > 0 })
        else {
            if ra.prefixes.contains(where: { $0.validLifetime == 0 }) || ra.routerLifetime == 0 { withdraw() }
            return
        }

        let updated = IPv6Configuration(
            address: IPv6Address(prefix: info.prefix, interfaceID: interfaceID),
            prefix: IPv6Address(prefix: info.prefix, interfaceID: [UInt8](repeating: 0, count: 8)),
            prefixLength: info.prefixLength,
            router: source,
            routerMAC: ra.sourceLinkLayer ?? sourceMAC,
            dnsServers: ra.dnsServers,
            mtu: ra.mtu,
            routerLifetime: ra.routerLifetime)
        scheduleExpiry(after: info.validLifetime)
        guard updated != configuration else { return }
        configuration = updated
        onConfigurationChange?(updated)
    }

    // MARK: Private

    private func solicit() {
        guard configuration == nil, solicitationsSent < maxSolicitations else { return }
        solicitationsSent += 1
        sendFrame(NDPMessage.routerSolicitation(sourceLinkLayer: mac)
            .frame(from: mac, to: IPv6Address.allRouters.multicastMAC,
                   source: linkLocal, destination: .allRouters))
        let item = DispatchWorkItem { [weak self] in self?.solicit() }
        solicitTimer = item
        queue.asyncAfter(deadline: .now() + solicitationInterval, execute: item)
    }

    private func scheduleExpiry(after seconds: UInt32) {
        expiryTimer?.cancel()
        guard seconds != UInt32.max else { return } // infinite
        let item = DispatchWorkItem { [weak self] in self?.withdraw() }
        expiryTimer = item
        queue.asyncAfter(deadline: .now() + TimeInterval(seconds), execute: item)
    }

    private func withdraw() {
        expiryTimer?.cancel()
        expiryTimer = nil
        guard configuration != nil else { return }
        configuration = nil
        onConfigurationChange?(nil)
    }
}
