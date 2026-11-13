import Foundation

/// Publishes the phone's DNS servers to macOS through the SystemConfiguration dynamic store.
public final class DNSConfigurator {
    public static let storeKey = "State:/Network/Service/AndroidUSBTethering/DNS"

    private let runner: CommandRunning
    private var applied = false

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// Publishes (or replaces) the DNS servers; IPv4 servers are listed first.
    public func apply(ipv4: [IPv4Address], ipv6: [IPv6Address] = []) throws {
        let servers = ipv4.map(\.description) + ipv6.map(\.description)
        guard !servers.isEmpty else { return remove() }
        try runner.run("/usr/sbin/scutil", [], input: Self.script(for: servers))
        applied = true
    }

    public func remove() {
        guard applied else { return }
        _ = try? runner.run("/usr/sbin/scutil", [], input: "remove \(Self.storeKey)\nquit\n")
        applied = false
    }

    static func script(for servers: [String]) -> String {
        """
        d.init
        d.add ServerAddresses * \(servers.joined(separator: " "))
        d.add SupplementalMatchDomains * ""
        set \(storeKey)
        quit

        """
    }
}
