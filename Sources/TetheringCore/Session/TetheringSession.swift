import Foundation

/// Options that control how the session configures macOS networking.
public struct TetheringOptions: Equatable, Codable {
    /// Route all IPv4 traffic through the phone (otherwise only its subnet).
    public var routeAllTraffic: Bool
    /// Publish the phone's DNS servers to macOS.
    public var usePhoneDNS: Bool

    public init(routeAllTraffic: Bool = true, usePhoneDNS: Bool = true) {
        self.routeAllTraffic = routeAllTraffic
        self.usePhoneDNS = usePhoneDNS
    }
}

/// Orchestrates one tethering connection: link bring-up → DHCP → interface → routes/DNS → bridging.
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
    private var bridge: PacketBridge?
    private var routerMAC: MACAddress?
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
        do {
            try interface.open()
            try interface.configure(with: lease)
            try routes.install(interface: interface.name, routeAllTraffic: options.routeAllTraffic)
            if options.usePhoneDNS { try dns.apply(servers: lease.dnsServers) }
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
        state = .connected(ConnectionInfo(deviceName: device.name, interfaceName: interface.name,
                                          address: lease.address, router: lease.router,
                                          dnsServers: lease.dnsServers))
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
        dhcp?.stop()
        dhcp = nil
        bridge = nil
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
