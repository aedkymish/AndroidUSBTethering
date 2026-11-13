import Foundation

public enum DHCPError: Error, LocalizedError, Equatable {
    case timeout
    case declined

    public var errorDescription: String? {
        switch self {
        case .timeout: return "The phone's DHCP server did not answer."
        case .declined: return "The phone's DHCP server refused the address request (NAK)."
        }
    }
}

/// User-space DHCP client (DISCOVER → OFFER → REQUEST → ACK, then RENEW at T1).
/// All methods must be called on `queue`.
public final class DHCPClient {
    public enum Phase: Equatable { case idle, selecting, requesting, bound, renewing }

    public private(set) var phase: Phase = .idle
    public private(set) var lease: DHCPLease?
    /// Called on the queue whenever a lease is obtained or renewed.
    public var onLease: ((DHCPLease) -> Void)?
    /// Called on the queue when a renewal fails after the initial lease was obtained.
    public var onLeaseLost: ((Error) -> Void)?

    private let mac: MACAddress
    private let hostName: String?
    private let queue: DispatchQueue
    private let sendFrame: (Data) -> Void
    private let retryInterval: TimeInterval
    private let maxAttempts: Int

    private var transactionID: UInt32 = 0
    private var attempts = 0
    private var offered: (address: IPv4Address, server: IPv4Address)?
    private var completion: ((Result<DHCPLease, Error>) -> Void)?
    private var timer: DispatchWorkItem?

    public init(mac: MACAddress, hostName: String? = Host.current().localizedName, queue: DispatchQueue,
                retryInterval: TimeInterval = 2, maxAttempts: Int = 5, sendFrame: @escaping (Data) -> Void) {
        self.mac = mac
        self.hostName = hostName
        self.queue = queue
        self.retryInterval = retryInterval
        self.maxAttempts = maxAttempts
        self.sendFrame = sendFrame
    }

    public func start(completion: @escaping (Result<DHCPLease, Error>) -> Void) {
        self.completion = completion
        transactionID = UInt32.random(in: 1...UInt32.max)
        attempts = 0
        phase = .selecting
        sendCurrent()
    }

    /// Returns `true` when the frame was a DHCP reply consumed by the client.
    @discardableResult
    public func handle(frame: EthernetFrame) -> Bool {
        guard let reply = DHCPMessage.reply(in: frame), reply.transactionID == transactionID,
              reply.clientMAC == mac else { return false }
        switch (phase, reply.messageType) {
        case (.selecting, .offer?):
            let server = reply.addressOption(DHCPOptionCode.serverIdentifier) ?? frame.sourceIPv4
            offered = (reply.yourAddress, server)
            phase = .requesting
            attempts = 0
            sendCurrent()
        case (.requesting, .ack?), (.renewing, .ack?):
            let newLease = makeLease(from: reply)
            lease = newLease
            phase = .bound
            cancelTimer()
            scheduleRenewal(after: TimeInterval(newLease.leaseTime) / 2)
            onLease?(newLease)
            completion?(.success(newLease))
            completion = nil
        case (.requesting, .nak?), (.renewing, .nak?):
            fail(DHCPError.declined)
        default:
            break
        }
        return true
    }

    /// Releases the lease (best effort) and stops all timers.
    public func stop() {
        cancelTimer()
        if let lease {
            let release = DHCPMessage.release(transactionID: UInt32.random(in: 1...UInt32.max), mac: mac,
                                              current: lease.address, server: lease.serverIdentifier)
            sendFrame(release.broadcastFrame(from: mac, source: lease.address))
        }
        lease = nil
        phase = .idle
        completion = nil
    }

    // MARK: Private

    private func sendCurrent() {
        attempts += 1
        guard attempts <= maxAttempts else { return fail(DHCPError.timeout) }
        let message: DHCPMessage
        var source = IPv4Address.any
        switch phase {
        case .selecting:
            message = .discover(transactionID: transactionID, mac: mac, hostName: hostName)
        case .requesting:
            guard let offered else { return fail(DHCPError.timeout) }
            message = .request(transactionID: transactionID, mac: mac, offered: offered.address,
                               server: offered.server, hostName: hostName)
        case .renewing:
            guard let lease else { return fail(DHCPError.timeout) }
            message = .renew(transactionID: transactionID, mac: mac, current: lease.address, hostName: hostName)
            source = lease.address
        case .idle, .bound:
            return
        }
        sendFrame(message.broadcastFrame(from: mac, source: source))
        scheduleRetry()
    }

    private func scheduleRetry() {
        schedule(after: retryInterval) { [weak self] in self?.sendCurrent() }
    }

    private func scheduleRenewal(after interval: TimeInterval) {
        schedule(after: max(interval, 30)) { [weak self] in
            guard let self, self.phase == .bound else { return }
            self.transactionID = UInt32.random(in: 1...UInt32.max)
            self.attempts = 0
            self.phase = .renewing
            self.sendCurrent()
        }
    }

    private func schedule(after interval: TimeInterval, _ block: @escaping () -> Void) {
        cancelTimer()
        let item = DispatchWorkItem(block: block)
        timer = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func fail(_ error: Error) {
        cancelTimer()
        phase = .idle
        if let completion {
            self.completion = nil
            completion(.failure(error))
        } else {
            lease = nil
            onLeaseLost?(error)
        }
    }

    private func makeLease(from reply: DHCPMessage) -> DHCPLease {
        let router = reply.addressListOption(DHCPOptionCode.router).first
            ?? offered?.server ?? lease?.router ?? .any
        let leaseTime = reply.option(DHCPOptionCode.leaseTime).flatMap { bytes -> UInt32? in
            bytes.count == 4 ? try? ByteReader(bytes).readBE(UInt32.self, at: 0) : nil
        } ?? 3600
        let mtu = reply.option(DHCPOptionCode.interfaceMTU).flatMap { bytes -> UInt16? in
            bytes.count == 2 ? try? ByteReader(bytes).readBE(UInt16.self, at: 0) : nil
        }
        return DHCPLease(
            address: reply.yourAddress,
            subnetMask: reply.addressOption(DHCPOptionCode.subnetMask) ?? IPv4Address(255, 255, 255, 0),
            router: router,
            dnsServers: reply.addressListOption(DHCPOptionCode.dns),
            serverIdentifier: reply.addressOption(DHCPOptionCode.serverIdentifier) ?? offered?.server ?? router,
            leaseTime: leaseTime,
            mtu: mtu)
    }
}

extension EthernetFrame {
    /// Source IPv4 address when the frame carries an IPv4 packet.
    var sourceIPv4: IPv4Address {
        guard type == .ipv4, let ip = try? IPv4Packet(decoding: payload) else { return .any }
        return ip.source
    }
}
