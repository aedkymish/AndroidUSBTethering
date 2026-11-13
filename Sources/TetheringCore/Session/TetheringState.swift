import Foundation

/// Details of an established tethering link, shown in the UI.
public struct ConnectionInfo: Equatable, Codable {
    public var deviceName: String
    public var interfaceName: String
    public var address: IPv4Address
    public var router: IPv4Address
    public var dnsServers: [IPv4Address]
    /// Present once the phone has advertised an IPv6 prefix.
    public var ipv6: IPv6Configuration?
    public var since: Date

    public init(deviceName: String, interfaceName: String, address: IPv4Address, router: IPv4Address,
                dnsServers: [IPv4Address], ipv6: IPv6Configuration? = nil, since: Date = Date()) {
        self.deviceName = deviceName
        self.interfaceName = interfaceName
        self.address = address
        self.router = router
        self.dnsServers = dnsServers
        self.ipv6 = ipv6
        self.since = since
    }
}

/// Lifecycle states of a tethering session (mirrors the BPMN process in docs/).
public enum TetheringState: Equatable, Codable {
    case idle
    case initializingLink
    case negotiatingDHCP
    case configuringNetwork
    case connected(ConnectionInfo)
    /// The phone uses CDC-NCM, which macOS drives natively.
    case nativeNCM(deviceName: String)
    /// The DriverKit extension owns the phone and exposes it as a native Ethernet interface;
    /// macOS configures DHCP, IPv6, DNS and routing itself.
    case nativeEthernet(deviceName: String, interfaceName: String?)
    case failed(message: String)

    public var isActive: Bool {
        switch self {
        case .initializingLink, .negotiatingDHCP, .configuringNetwork, .connected: return true
        case .idle, .nativeNCM, .nativeEthernet, .failed: return false
        }
    }

    public var summary: String {
        switch self {
        case .idle: return "Waiting for an Android phone"
        case .initializingLink: return "Initializing RNDIS link…"
        case .negotiatingDHCP: return "Requesting an IP address…"
        case .configuringNetwork: return "Configuring network…"
        case let .connected(info): return "Connected via \(info.deviceName)"
        case let .nativeNCM(name): return "\(name) uses NCM (handled by macOS)"
        case let .nativeEthernet(name, interface):
            return "Connected via \(name) (Ethernet\(interface.map { " " + $0 } ?? ""))"
        case let .failed(message): return "Error: \(message)"
        }
    }
}
