import Foundation

/// Publishes the phone's DNS servers to macOS through the SystemConfiguration dynamic store.
public final class DNSConfigurator {
    public static let storeKey = "State:/Network/Service/AndroidUSBTethering/DNS"

    private let runner: CommandRunning
    private var applied = false

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func apply(servers: [IPv4Address]) throws {
        guard !servers.isEmpty else { return }
        try runner.run("/usr/sbin/scutil", [], input: Self.script(for: servers))
        applied = true
    }

    public func remove() {
        guard applied else { return }
        _ = try? runner.run("/usr/sbin/scutil", [], input: "remove \(Self.storeKey)\nquit\n")
        applied = false
    }

    static func script(for servers: [IPv4Address]) -> String {
        """
        d.init
        d.add ServerAddresses * \(servers.map(\.description).joined(separator: " "))
        d.add SupplementalMatchDomains * ""
        set \(storeKey)
        quit

        """
    }
}
