import Foundation

/// Options that control how the session configures macOS networking.
public struct TetheringOptions: Equatable, Codable {
    /// Route all internet traffic through the phone (otherwise only its local subnets).
    public var routeAllTraffic: Bool
    /// Publish the phone's DNS servers to macOS.
    public var usePhoneDNS: Bool
    /// Configure IPv6 from the phone's Router Advertisements (SLAAC).
    public var enableIPv6: Bool

    public init(routeAllTraffic: Bool = true, usePhoneDNS: Bool = true, enableIPv6: Bool = true) {
        self.routeAllTraffic = routeAllTraffic
        self.usePhoneDNS = usePhoneDNS
        self.enableIPv6 = enableIPv6
    }

    /// Tolerates settings saved by older versions (missing keys fall back to defaults).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TetheringOptions()
        routeAllTraffic = try container.decodeIfPresent(Bool.self, forKey: .routeAllTraffic) ?? defaults.routeAllTraffic
        usePhoneDNS = try container.decodeIfPresent(Bool.self, forKey: .usePhoneDNS) ?? defaults.usePhoneDNS
        enableIPv6 = try container.decodeIfPresent(Bool.self, forKey: .enableIPv6) ?? defaults.enableIPv6
    }
}

/// Orchestrates one tethering connection:
/// link bring-up → DHCPv4 → interface → routes/DNS → bridging, then IPv6 SLAAC in the background.
/// Implements the "RNDIS" branch of docs/tethering-process.bpmn as a state machine.
public final class TetheringSession {
    public private(set) var state: TetheringState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((TetheringState) -> Void)?

    public let device: AndroidDevice
    private let transport: TetheringTransport
    private let interface: VirtualInterface
    private let routes: RouteManager
    private let dns: DNSConfigurator
    private let options: TetheringOptions
    private let queue: DispatchQueue

    private var dhcp: DHCPClient?
    private var slaac: SLAACClient?
    private var bridge: PacketBridge?
    private var routerMAC: MACAddress?
    private var lease: DHCPLease?
    private var ipv6: IPv6Configuration?
    private var transportStarted = false

    public init(device: AndroidDevice, transport: TetheringTransport, interface: VirtualInterface,
                routes: RouteManager = RouteManager(), dns: DNSConfigurator = DNSConfigurator(),
                options: TetheringOptions = TetheringOptions(),
                queue: DispatchQueue = DispatchQueue(label: "AndroidUSBTethering.session")) {
        self.device = device
        self.transport = transport
        self.interface = interface
        self.routes = routes
        self.dns = dns
        self.options = options
        self.queue = queue
    }

    /// Starts the connection asynchronously on the session queue.
    public func start() {
        queue.async { self.bringUpLink() }
    }

    /// Tears everything down; safe to call more than once.
    public func stop() {
        queue.async { self.teardown(finalState: .idle) }
    }

    // MARK: Process steps

    private func bringUpLink() {
        guard !state.isActive else { return }
        state = .initializingLink
        transport.onFrameReceived = { [weak self] data in
            self?.queue.async { self?.receive(frameData: data) }
        }
        transport.onDisconnect = { [weak self] error in
            self?.queue.async {
                self?.teardown(finalState: .failed(message: error?.localizedDescription ?? "Phone disconnected"))
            }
        }
        transportStarted = true
        do {
            try transport.open()
        } catch {
            return teardown(finalState: .failed(message: error.localizedDescription))
        }
        negotiateAddress()
    }

    private func negotiateAddress() {
        state = .negotiatingDHCP
        let client = DHCPClient(mac: transport.macAddress, queue: queue) { [weak self] frame in
            self?.sendToPhone(frame)
        }
        client.onLeaseLost = { [weak self] error in
            self?.teardown(finalState: .failed(message: error.localizedDescription))
        }
        dhcp = client
        client.start { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(lease): self.configureNetwork(with: lease)
            case let .failure(error): self.teardown(finalState: .failed(message: error.localizedDescription))
            }
        }
    }

    private func configureNetwork(with lease: DHCPLease) {
        state = .configuringNetwork
        self.lease = lease
        do {
            try interface.open()
            try interface.configure(with: lease)
            try routes.install(interface: interface.name, routeAllTraffic: options.routeAllTraffic)
            try applyDNS()
        } catch {
            return teardown(finalState: .failed(message: error.localizedDescription))
        }

        let bridge = PacketBridge(hostMAC: transport.macAddress, lease: lease,
                                  sendToPhone: { [weak self] in self?.sendToPhone($0) },
                                  deliverToHost: { [weak self] in try? self?.interface.write(ipPacket: $0) })
        if let routerMAC { bridge.prime(routerMAC: routerMAC) }
        self.bridge = bridge
        interface.onPacket = { [weak self] packet in
            self?.queue.async { self?.bridge?.handleOutbound(ipPacket: packet) }
        }
        publishConnected()
        if options.enableIPv6 { startIPv6(on: bridge) }
    }

    // MARK: IPv6 (SLAAC)

    private func startIPv6(on bridge: PacketBridge) {
        let client = SLAACClient(mac: transport.macAddress, queue: queue) { [weak self] frame in
            self?.sendToPhone(frame)
        }
        client.onConfigurationChange = { [weak self] configuration in
            self?.applyIPv6(configuration)
        }
        bridge.enableIPv6(linkLocal: client.linkLocal)
        bridge.onRouterAdvertisement = { [weak client] ra, source, mac in
            client?.handle(advertisement: ra, from: source, sourceMAC: mac)
        }
        slaac = client
        client.start()
    }

    /// Adds, replaces or removes the IPv6 address, routes and DNS. IPv4 keeps working if this fails.
    private func applyIPv6(_ configuration: IPv6Configuration?) {
        let previous = ipv6
        let addressChanged = previous?.address != configuration?.address
        let routingChanged = previous?.isDefaultRouter != configuration?.isDefaultRouter

        if addressChanged, let previous { interface.removeIPv6(previous) }
        if addressChanged || routingChanged { routes.removeIPv6() }

        var applied = configuration
        if let configuration {
            do {
                if addressChanged { try interface.configureIPv6(with: configuration) }
                if addressChanged || routingChanged {
                    try routes.installIPv6(interface: interface.name,
                                           routeAllTraffic: options.routeAllTraffic && configuration.isDefaultRouter)
                }
            } catch {
                interface.removeIPv6(configuration)
                routes.removeIPv6()
                applied = nil
            }
        }

        ipv6 = applied
        bridge?.setIPv6(applied)
        try? applyDNS()
        publishConnected()
    }

    // MARK: Helpers

    private func applyDNS() throws {
        guard options.usePhoneDNS, let lease else { return }
        try dns.apply(ipv4: lease.dnsServers, ipv6: ipv6?.dnsServers ?? [])
    }

    private func publishConnected() {
        guard let lease else { return }
        let since: Date
        if case let .connected(info) = state { since = info.since } else { since = Date() }
        state = .connected(ConnectionInfo(deviceName: device.name, interfaceName: interface.name,
                                          address: lease.address, router: lease.router,
                                          dnsServers: lease.dnsServers, ipv6: ipv6, since: since))
    }

    private func receive(frameData: Data) {
        guard let frame = try? EthernetFrame(decoding: frameData) else { return }
        if let dhcp, dhcp.handle(frame: frame) {
            if routerMAC == nil { routerMAC = frame.source }
            return
        }
        bridge?.handleInbound(frame: frame)
    }

    private func sendToPhone(_ frame: Data) {
        do {
            try transport.send(frame: frame)
        } catch {
            // Dropped frame; persistent failures surface through transport.onDisconnect.
        }
    }

    private func teardown(finalState: TetheringState) {
        slaac?.stop()
        slaac = nil
        dhcp?.stop()
        dhcp = nil
        bridge = nil
        ipv6 = nil
        lease = nil
        interface.onPacket = nil
        dns.remove()
        routes.removeAll()
        interface.close()
        transport.onFrameReceived = nil
        transport.onDisconnect = nil
        if transportStarted {
            transportStarted = false
            transport.close()
        }
        if state != finalState { state = finalState }
    }
}
