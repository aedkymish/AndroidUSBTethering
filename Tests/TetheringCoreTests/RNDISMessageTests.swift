@testable import TetheringCore
import XCTest

final class RNDISMessageTests: XCTestCase {
    func testInitializeEncodingMatchesSpec() {
        let bytes = [UInt8](RNDISMessage.initialize(requestID: 1, maxTransferSize: 0x4000).encoded())
        XCTAssertEqual(bytes, [
            0x02, 0, 0, 0,   // REMOTE_NDIS_INITIALIZE_MSG
            0x18, 0, 0, 0,   // length 24
            0x01, 0, 0, 0,   // request id
            0x01, 0, 0, 0,   // major
            0x00, 0, 0, 0,   // minor
            0x00, 0x40, 0, 0 // max transfer size
        ])
    }

    func testQueryEncodingUsesOffsetFromRequestID() throws {
        let bytes = [UInt8](RNDISMessage.query(requestID: 7, oid: RNDISOID.permanentAddress.rawValue, buffer: Data()).encoded())
        XCTAssertEqual(bytes.count, 28)
        let reader = ByteReader(bytes)
        XCTAssertEqual(try reader.readLE(UInt32.self, at: 0), RNDISMessageType.query.rawValue)
        XCTAssertEqual(try reader.readLE(UInt32.self, at: 12), 0x0101_0101)
        XCTAssertEqual(try reader.readLE(UInt32.self, at: 20), 0)
    }

    func testSetCarriesBufferAtOffset20() throws {
        let value = Data([0x0D, 0, 0, 0])
        let message = RNDISMessage.set(requestID: 3, oid: RNDISOID.genCurrentPacketFilter.rawValue, buffer: value)
        XCTAssertEqual(try RNDISMessage(decoding: message.encoded()), message)
        let reader = ByteReader(message.encoded())
        XCTAssertEqual(try reader.readLE(UInt32.self, at: 20), 20)
        XCTAssertEqual(try reader.slice(28, 4), [0x0D, 0, 0, 0])
    }

    func testDecodeQueryCompleteWithMAC() throws {
        let mac: [UInt8] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
        let message = RNDISMessage.queryComplete(requestID: 2, status: RNDISStatus.success, buffer: Data(mac))
        let decoded = try RNDISMessage(decoding: message.encoded())
        guard case let .queryComplete(id, status, buffer) = decoded else { return XCTFail("wrong case") }
        XCTAssertEqual(id, 2)
        XCTAssertEqual(status, RNDISStatus.success)
        XCTAssertEqual([UInt8](buffer), mac)
    }

    func testInitializeCompleteRoundTrip() throws {
        let body = RNDISMessage.InitializeComplete(requestID: 1, status: 0, majorVersion: 1, minorVersion: 0,
                                                   deviceFlags: 1, medium: 0, maxPacketsPerTransfer: 1,
                                                   maxTransferSize: 1580, packetAlignmentFactor: 0)
        XCTAssertEqual(try RNDISMessage(decoding: RNDISMessage.initializeComplete(body).encoded()),
                       .initializeComplete(body))
    }

    func testPacketWrapAndUnwrapMultipleFrames() throws {
        let first = Data(repeating: 0xAB, count: 60)
        let second = Data(repeating: 0xCD, count: 90)
        let wrapped = RNDISPacketCodec.wrap(first)
        XCTAssertEqual(wrapped.count, 44 + 60)
        XCTAssertEqual(try ByteReader(wrapped).readLE(UInt32.self, at: 8), 36)

        let transfer = wrapped + RNDISPacketCodec.wrap(second) + Data(count: 8)
        XCTAssertEqual(try RNDISPacketCodec.unwrap(transfer), [first, second])
    }

    func testUnwrapRejectsTruncatedMessage() {
        let wrapped = RNDISPacketCodec.wrap(Data(count: 60))
        XCTAssertThrowsError(try RNDISPacketCodec.unwrap(wrapped.prefix(70)))
    }
}
