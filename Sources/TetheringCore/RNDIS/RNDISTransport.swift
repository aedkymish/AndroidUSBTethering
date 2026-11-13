import Foundation

public enum RNDISError: Error, LocalizedError, Equatable {
    case notOpen
    case timeout(String)
    case deviceStatus(String, UInt32)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notOpen: return "The RNDIS link is not open."
        case let .timeout(step): return "The phone did not answer \(step) in time."
        case let .deviceStatus(step, status): return String(format: "%@ failed with RNDIS status 0x%08x.", step, status)
        case let .unexpectedResponse(step): return "Unexpected RNDIS response during \(step)."
        }
    }
}

/// `TetheringTransport` that speaks Microsoft RNDIS over a `RNDISUSBChannel`.
public final class RNDISTransport: TetheringTransport {
    public static let requestedMaxTransferSize: UInt32 = 16_384
    public static let controlBufferSize = 1_025

    public private(set) var macAddress: MACAddress = .zero
    public var onFrameReceived: ((Data) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let channel: RNDISUSBChannel
    private let responsePollInterval: TimeInterval
    private let responseTimeout: TimeInterval
    private var nextRequestID: UInt32 = 1
    private var maxTransferSize = Int(RNDISTransport.requestedMaxTransferSize)
    private var isOpen = false

    public init(channel: RNDISUSBChannel, responsePollInterval: TimeInterval = 0.01, responseTimeout: TimeInterval = 5) {
        self.channel = channel
        self.responsePollInterval = responsePollInterval
        self.responseTimeout = responseTimeout
    }

    public func open() throws {
        // 1. INITIALIZE
        let initResponse = try request(.initialize(requestID: makeRequestID(),
                                                   maxTransferSize: Self.requestedMaxTransferSize),
                                       step: "INITIALIZE")
        guard case let .initializeComplete(body) = initResponse else {
            throw RNDISError.unexpectedResponse("INITIALIZE")
        }
        guard body.status == RNDISStatus.success else { throw RNDISError.deviceStatus("INITIALIZE", body.status) }
        if body.maxTransferSize > 0 {
            maxTransferSize = Int(min(body.maxTransferSize, Self.requestedMaxTransferSize))
        }

        // 2. QUERY permanent MAC address
        let macData = try query(oid: .permanentAddress, step: "QUERY MAC")
        guard let mac = MACAddress([UInt8](macData.prefix(6))) else {
            throw RNDISError.unexpectedResponse("QUERY MAC")
        }
        macAddress = mac

        // 3. SET packet filter — the device starts forwarding frames after this.
        var filter = ByteWriter()
        filter.writeLE(RNDISPacketFilter.standard.rawValue)
        try set(oid: .genCurrentPacketFilter, value: filter.data, step: "SET PACKET FILTER")

        isOpen = true
        channel.startBulkReading(transferSize: maxTransferSize) { [weak self] result in
            self?.handleBulk(result)
        }
    }

    public func send(frame: Data) throws {
        guard isOpen else { throw RNDISError.notOpen }
        try channel.writeBulk(RNDISPacketCodec.wrap(frame))
    }

    public func close() {
        if isOpen {
            try? channel.sendEncapsulatedCommand(RNDISMessage.halt(requestID: makeRequestID()).encoded())
        }
        isOpen = false
        channel.close()
    }

    // MARK: Control plane

    func query(oid: RNDISOID, step: String) throws -> Data {
        let response = try request(.query(requestID: makeRequestID(), oid: oid.rawValue, buffer: Data()), step: step)
        guard case let .queryComplete(_, status, buffer) = response else { throw RNDISError.unexpectedResponse(step) }
        guard status == RNDISStatus.success else { throw RNDISError.deviceStatus(step, status) }
        return buffer
    }

    func set(oid: RNDISOID, value: Data, step: String) throws {
        let response = try request(.set(requestID: makeRequestID(), oid: oid.rawValue, buffer: value), step: step)
        guard case let .setComplete(_, status) = response else { throw RNDISError.unexpectedResponse(step) }
        guard status == RNDISStatus.success else { throw RNDISError.deviceStatus(step, status) }
    }

    /// Sends a control message and polls for the completion that carries the same request ID,
    /// answering any KEEPALIVE the device sends in the meantime.
    private func request(_ message: RNDISMessage, step: String) throws -> RNDISMessage {
        try channel.sendEncapsulatedCommand(message.encoded())
        let deadline = Date().addingTimeInterval(responseTimeout)
        while Date() < deadline {
            let raw = try channel.getEncapsulatedResponse(maxLength: Self.controlBufferSize)
            if raw.count >= 8, let response = try? RNDISMessage(decoding: raw) {
                switch response {
                case let .keepAlive(id):
                    try channel.sendEncapsulatedCommand(
                        RNDISMessage.keepAliveComplete(requestID: id, status: RNDISStatus.success).encoded())
                case .indicateStatus:
                    continue
                default:
                    if response.requestID == message.requestID { return response }
                }
            } else {
                Thread.sleep(forTimeInterval: responsePollInterval)
            }
        }
        throw RNDISError.timeout(step)
    }

    private func makeRequestID() -> UInt32 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    // MARK: Data plane

    private func handleBulk(_ result: Result<Data, Error>) {
        switch result {
        case let .success(transfer):
            guard let frames = try? RNDISPacketCodec.unwrap(transfer) else { return }
            frames.forEach { onFrameReceived?($0) }
        case let .failure(error):
            isOpen = false
            onDisconnect?(error)
        }
    }
}
