import Foundation

/// IPv4 configuration obtained from the phone's DHCP server.
public struct DHCPLease: Equatable, Codable {
    public var address: IPv4Address
    public var subnetMask: IPv4Address
    public var router: IPv4Address
    public var dnsServers: [IPv4Address]
    public var serverIdentifier: IPv4Address
    public var leaseTime: UInt32
    public var mtu: UInt16?

    public init(address: IPv4Address, subnetMask: IPv4Address, router: IPv4Address,
                dnsServers: [IPv4Address], serverIdentifier: IPv4Address, leaseTime: UInt32, mtu: UInt16? = nil) {
        self.address = address
        self.subnetMask = subnetMask
        self.router = router
        self.dnsServers = dnsServers
        self.serverIdentifier = serverIdentifier
        self.leaseTime = leaseTime
        self.mtu = mtu
    }
}

/// A host-side network interface that carries IP packets to and from the bridge.
public protocol VirtualInterface: AnyObject {
    /// BSD interface name, e.g. `utun7`.
    var name: String { get }
    /// Called for every IPv4 or IPv6 packet the macOS network stack sends through the interface.
    var onPacket: ((Data) -> Void)? { get set }

    func open() throws
    func configure(with lease: DHCPLease) throws
    /// Adds the SLAAC address (prefix route included).
    func configureIPv6(with configuration: IPv6Configuration) throws
    /// Removes a previously added SLAAC address (best effort).
    func removeIPv6(_ configuration: IPv6Configuration)
    func write(ipPacket: Data) throws
    func close()
}
