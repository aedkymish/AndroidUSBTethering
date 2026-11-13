@testable import TetheringCore
import XCTest

final class RecordingRunner: CommandRunning {
    var calls: [(String, [String], String?)] = []
    func run(_ executable: String, _ arguments: [String], input: String?) throws -> String {
        calls.append((executable, arguments, input))
        return ""
    }
}

final class SystemConfigurationTests: XCTestCase {
    func testRouteManagerInstallsAndRemovesSplitDefaultRoutes() {
        let runner = RecordingRunner()
        let routes = RouteManager(runner: runner)
        XCTAssertNoThrow(try routes.install(interface: "utun9", routeAllTraffic: true))
        routes.removeAll()
        XCTAssertEqual(runner.calls.map { $0.1 }, [
            ["-q", "-n", "add", "-net", "0.0.0.0/1", "-interface", "utun9"],
            ["-q", "-n", "add", "-net", "128.0.0.0/1", "-interface", "utun9"],
            ["-q", "-n", "delete", "-net", "0.0.0.0/1", "-interface", "utun9"],
            ["-q", "-n", "delete", "-net", "128.0.0.0/1", "-interface", "utun9"],
        ])
    }

    func testDNSScriptListsServers() {
        let script = DNSConfigurator.script(for: [IPv4Address(192, 168, 42, 129), IPv4Address(8, 8, 8, 8)])
        XCTAssertTrue(script.contains("d.add ServerAddresses * 192.168.42.129 8.8.8.8"))
        XCTAssertTrue(script.contains("set \(DNSConfigurator.storeKey)"))
    }

    func testDescriptorParserFindsRNDISDataInterface() {
        // Config header, IAD skipped, control iface 0 (E0/01/03) + interrupt EP, data iface 1 (0A) + 2 bulk EPs.
        let config: [UInt8] = [
            9, 2, 75, 0, 2, 1, 0, 0x80, 250,
            8, 0x0B, 0, 2, 0xE0, 0x01, 0x03, 0,
            9, 4, 0, 0, 1, 0xE0, 0x01, 0x03, 0,
            7, 5, 0x81, 3, 8, 0, 9,
            9, 4, 1, 0, 2, 0x0A, 0, 0, 0,
            7, 5, 0x82, 2, 0, 2, 0,
            7, 5, 0x01, 2, 0, 2, 0,
        ]
        let interfaces = USBDescriptorParser.interfaces(inConfiguration: config)
        XCTAssertEqual(interfaces.count, 2)
        XCTAssertTrue(interfaces[0].matches(USBClassCode.rndisWireless))
        let data = USBDescriptorParser.dataInterface(forControl: 0, in: interfaces)
        XCTAssertEqual(data?.number, 1)
        XCTAssertEqual(data?.bulkIn?.address, 0x82)
        XCTAssertEqual(data?.bulkOut?.address, 0x01)
        XCTAssertEqual(data?.bulkIn?.maxPacketSize, 512)
    }
}
