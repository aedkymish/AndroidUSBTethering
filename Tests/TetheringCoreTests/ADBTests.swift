@testable import TetheringCore
import XCTest

final class ADBTests: XCTestCase {
    func testParsesDeviceList() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        28041FDH2000FY         device usb:1-1 product:panther model:Pixel_7 device:panther transport_id:1
        R58N12ABCDE            unauthorized usb:1-2 transport_id:2
        emulator-5554          offline

        """
        let devices = ADBDevice.parseList(output)
        XCTAssertEqual(devices, [
            ADBDevice(serial: "28041FDH2000FY", state: .device, model: "Pixel 7", product: "panther"),
            ADBDevice(serial: "R58N12ABCDE", state: .unauthorized),
            ADBDevice(serial: "emulator-5554", state: .offline),
        ])
        XCTAssertEqual(devices[0].displayName, "Pixel 7")
        XCTAssertEqual(devices[1].displayName, "R58N12ABCDE")
    }

    func testEnableAndDisableTetheringCommands() throws {
        let runner = RecordingRunner()
        let client = ADBClient(executable: "/opt/homebrew/bin/adb", runner: runner)
        let phone = ADBDevice(serial: "ABC", state: .device, model: "Pixel 7")

        try client.enableTethering(on: phone, function: .ncm)
        try client.disableTethering(on: phone)

        XCTAssertEqual(runner.calls.map { $0.0 }, ["/opt/homebrew/bin/adb", "/opt/homebrew/bin/adb"])
        XCTAssertEqual(runner.calls.map { $0.1 }, [
            ["-s", "ABC", "shell", "svc", "usb", "setFunctions", "ncm"],
            ["-s", "ABC", "shell", "svc", "usb", "setFunctions"],
        ])
    }

    func testUnauthorizedDeviceIsRejectedWithoutRunningADB() {
        let runner = RecordingRunner()
        let client = ADBClient(executable: "/usr/local/bin/adb", runner: runner)
        XCTAssertThrowsError(try client.enableTethering(on: ADBDevice(serial: "X", state: .unauthorized),
                                                        function: .rndis)) {
            XCTAssertEqual($0 as? ADBError, .unauthorized("X"))
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testMissingADBReportsNotInstalled() {
        let client = ADBClient(executable: nil, runner: RecordingRunner())
        XCTAssertFalse(client.isAvailable)
        XCTAssertThrowsError(try client.devices()) { XCTAssertEqual($0 as? ADBError, .notInstalled) }
    }

    func testShellErrorOutputIsReported() {
        final class FailingShell: CommandRunning {
            func run(_ executable: String, _ arguments: [String], input: String?) throws -> String {
                "Error: java.lang.SecurityException: MANAGE_USB required"
            }
        }
        let client = ADBClient(executable: "/usr/local/bin/adb", runner: FailingShell())
        XCTAssertThrowsError(try client.enableTethering(on: ADBDevice(serial: "A", state: .device), function: .rndis))
    }

    func testLocatorPrefersAndroidHome() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tools = directory.appendingPathComponent("platform-tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let adb = tools.appendingPathComponent("adb")
        FileManager.default.createFile(atPath: adb.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }

        let locator = ADBLocator(environment: ["ANDROID_HOME": directory.path], home: "/nonexistent")
        XCTAssertEqual(locator.locate(), adb.path)
        XCTAssertNil(ADBLocator(environment: [:], home: "/nonexistent", fileManager: NoFiles()).locate())
    }
}

private final class NoFiles: FileManager {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}
