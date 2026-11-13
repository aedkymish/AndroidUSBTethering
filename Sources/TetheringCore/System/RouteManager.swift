import Foundation

/// Installs and removes the routes that send traffic through the tethering interface.
public final class RouteManager {
    /// Two half-space routes override the default route without deleting it (the same trick VPNs use),
    /// so Wi-Fi comes back automatically when tethering stops.
    static let splitDefaultRoutes = ["0.0.0.0/1", "128.0.0.0/1"]
    static let splitDefaultRoutesIPv6 = ["::/1", "8000::/1"]

    private let runner: CommandRunning
    private var installed: [String] = []
    private var installedIPv6: [String] = []
    private var interfaceName = ""

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func install(interface: String, routeAllTraffic: Bool) throws {
        interfaceName = interface
        guard routeAllTraffic else { return }
        for network in Self.splitDefaultRoutes {
            try runner.run("/sbin/route", ["-q", "-n", "add", "-net", network, "-interface", interface])
            installed.append(network)
        }
    }

    /// Adds IPv6 default routes (the /64 prefix route comes with the interface address).
    public func installIPv6(interface: String, routeAllTraffic: Bool) throws {
        interfaceName = interface
        guard routeAllTraffic else { return }
        for network in Self.splitDefaultRoutesIPv6 {
            try runner.run("/sbin/route", ["-q", "-n", "add", "-inet6", network, "-interface", interface])
            installedIPv6.append(network)
        }
    }

    public func removeIPv6() {
        for network in installedIPv6 {
            _ = try? runner.run("/sbin/route", ["-q", "-n", "delete", "-inet6", network, "-interface", interfaceName])
        }
        installedIPv6.removeAll()
    }

    public func removeAll() {
        for network in installed {
            _ = try? runner.run("/sbin/route", ["-q", "-n", "delete", "-net", network, "-interface", interfaceName])
        }
        installed.removeAll()
        removeIPv6()
    }
}
