import Foundation

/// Installs and removes the routes that send traffic through the tethering interface.
public final class RouteManager {
    /// Two /1 routes override the default route without deleting it (the same trick VPNs use),
    /// so Wi-Fi comes back automatically when tethering stops.
    static let splitDefaultRoutes = ["0.0.0.0/1", "128.0.0.0/1"]

    private let runner: CommandRunning
    private var installed: [String] = []
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

    public func removeAll() {
        for network in installed {
            try? runner.run("/sbin/route", ["-q", "-n", "delete", "-net", network, "-interface", interfaceName])
        }
        installed.removeAll()
    }
}
