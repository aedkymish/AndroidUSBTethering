@testable import TetheringCore
import XCTest

/// Fake phone that answers RNDIS control messages like an Android device.
final class MockRNDISChannel: RNDISUSBChannel {
    var sentCommands: [RNDISMessage] = []
    var bulkWrites: [Data] = []
    var pendingResponses: [Data] = []
    var bulkHandler: ((Result<Data, Error>) -> Void)?
    var closed = false
    let mac: [UInt8] = [0x02, 0x4F, 0x1D, 0x22, 0x33, 0x44]

    func sendEncapsulatedCommand(_ message: Data) throws {
        let decoded = try RNDISMessage(decoding: message)
        sentCommands.append(decoded)
        switch decoded {
        case let .initialize(id, _):
            pendingResponses.append(RNDISMessage.keepAlive(requestID: 99).encoded()) // interleaved keep-alive
            pendingResponses.append(RNDISMessage.initializeComplete(.init(
                requestID: id, status: 0, majorVersion: 1, minorVersion: 0, deviceFlags: 1, medium: 0,
                maxPacketsPerTransfer: 1, maxTransferSize: 1580, packetAlignmentFactor: 0)).encoded())
        case let .query(id, oid, _) where oid == RNDISOID.permanentAddress.rawValue:
            pendingResponses.append(RNDISMessage.queryComplete(requestID: id, status: 0, buffer: Data(mac)).encoded())
        case let .set(id, _, _):
            pendingResponses.append(RNDISMessage.setComplete(requestID: id, status: 0).encoded())
        default:
            break
        }
    }

    func getEncapsulatedResponse(maxLength: Int) throws -> Data {
        pendingResponses.isEmpty ? Data() : pendingResponses.removeFirst()
    }

    func writeBulk(_ data: Data) throws { bulkWrites.append(data) }

    func startBulkReading(transferSize: Int, handler: @escaping (Result<Data, Error>) -> Void) {
        bulkHandler = handler
    }

    func close() { closed = true }
}

final class RNDISTransportTests: XCTestCase {
    func testOpenPerformsHandshakeAndAnswersKeepAlive() throws {
        let channel = MockRNDISChannel()
        let transport = RNDISTransport(channel: channel, responsePollInterval: 0, responseTimeout: 1)
        try transport.open()

        XCTAssertEqual(transport.macAddress, MACAddress(channel.mac))
        XCTAssertTrue(channel.sentCommands.contains(.keepAliveComplete(requestID: 99, status: 0)))
        XCTAssertTrue(channel.sentCommands.contains {
            if case let .set(_, oid, buffer) = $0 {
                return oid == RNDISOID.genCurrentPacketFilter.rawValue && buffer == Data([0x0D, 0, 0, 0])
            }
            return false
        })
        XCTAssertNotNil(channel.bulkHandler)
    }

    func testFramesAreWrappedAndUnwrapped() throws {
        let channel = MockRNDISChannel()
        let transport = RNDISTransport(channel: channel, responsePollInterval: 0, responseTimeout: 1)
        try transport.open()

        let frame = Data(repeating: 0x42, count: 64)
        try transport.send(frame: frame)
        XCTAssertEqual(try RNDISPacketCodec.unwrap(channel.bulkWrites[0]), [frame])

        var received: [Data] = []
        transport.onFrameReceived = { received.append($0) }
        channel.bulkHandler?(.success(RNDISPacketCodec.wrap(frame)))
        XCTAssertEqual(received, [frame])
    }

    func testTimeoutWhenPhoneIsSilent() {
        final class SilentChannel: RNDISUSBChannel {
            func sendEncapsulatedCommand(_ message: Data) throws {}
            func getEncapsulatedResponse(maxLength: Int) throws -> Data { Data() }
            func writeBulk(_ data: Data) throws {}
            func startBulkReading(transferSize: Int, handler: @escaping (Result<Data, Error>) -> Void) {}
            func close() {}
        }
        let transport = RNDISTransport(channel: SilentChannel(), responsePollInterval: 0.001, responseTimeout: 0.05)
        XCTAssertThrowsError(try transport.open()) { error in
            XCTAssertEqual(error as? RNDISError, .timeout("INITIALIZE"))
        }
    }
}
