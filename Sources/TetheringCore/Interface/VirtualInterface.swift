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
    /// Called for every IPv4 packet the macOS network stack sends through the interface.
    var onPacket: ((Data) -> Void)? { get set }

    func open() throws
    func configure(with lease: DHCPLease) throws
    func write(ipPacket: Data) throws
    func close()
}
