@testable import TetheringCore
import XCTest

final class NetworkingTests: XCTestCase {
    func testMACAddressParsingAndFormatting() {
        let mac = MACAddress("02:1a:11:FF:00:9c")
        XCTAssertEqual(mac?.description, "02:1a:11:ff:00:9c")
        XCTAssertNil(MACAddress("02:1a:11"))
        XCTAssertTrue(MACAddress.broadcast.isBroadcast)
        XCTAssertTrue(MACAddress("01:00:5e:00:00:01")!.isMulticast)
    }

    func testIPv4AddressRoundTripAndSubnet() {
        let ip = IPv4Address("192.168.42.129")!
        XCTAssertEqual(ip.bytes, [192, 168, 42, 129])
        XCTAssertEqual(ip.description, "192.168.42.129")
        XCTAssertTrue(ip.isInSameSubnet(as: IPv4Address(192, 168, 42, 1), mask: IPv4Address(255, 255, 255, 0)))
        XCTAssertFalse(ip.isInSameSubnet(as: IPv4Address(10, 0, 0, 1), mask: IPv4Address(255, 255, 255, 0)))
    }

    func testEthernetFrameRoundTrip() throws {
        let frame = EthernetFrame(destination: .broadcast, source: MACAddress("02:00:00:00:00:01")!,
                                  type: .arp, payload: Data([1, 2, 3]))
        let decoded = try EthernetFrame(decoding: frame.encoded())
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded.type, .arp)
    }

    func testIPv4HeaderChecksumValidates() throws {
        let packet = IPv4Packet(source: IPv4Address(10, 0, 0, 1), destination: IPv4Address(10, 0, 0, 2),
                                protocolNumber: IPv4Packet.protocolUDP, payload: Data([0xAA, 0xBB]))
        let bytes = [UInt8](packet.encoded())
        XCTAssertEqual(InternetChecksum.compute(Array(bytes[0..<20])), 0, "checksum over a valid header is 0")
        XCTAssertEqual(try IPv4Packet(decoding: Data(bytes)), packet)
        XCTAssertEqual(IPv4Packet.destination(of: Data(bytes)), IPv4Address(10, 0, 0, 2))
    }

    func testUDPDatagramRoundTrip() throws {
        let udp = UDPDatagram(sourcePort: 68, destinationPort: 67, payload: Data("hi".utf8))
        XCTAssertEqual(try UDPDatagram(decoding: udp.encoded()), udp)
    }
}
