import Foundation
import IOKit

/// Detects whether the AndroidRNDISDriver DriverKit extension has claimed an RNDIS interface,
/// and finds the BSD name (enX) of the Ethernet interface it registered.
public enum DriverKitDetector {
    /// `IOUserClass` of the driver in Driver/Info.plist.
    public static let driverUserClass = "AndroidRNDISDriver"
    /// Bundle identifier of the driver extension.
    public static let driverBundleIdentifier = "com.aedkymish.AndroidUSBTethering.RNDISDriver"

    public struct Match: Equatable {
        public let bsdName: String?
    }

    /// Returns a match when the driver is attached below `interfaceService`.
    public static func match(for interfaceService: io_service_t) -> Match? {
        for child in IORegistry.children(interfaceService) {
            defer { IOObjectRelease(child) }
            if IORegistry.property(child, "IOUserClass", as: String.self) == driverUserClass {
                return Match(bsdName: bsdName(below: child, depth: 3))
            }
        }
        return nil
    }

    private static func bsdName(below service: io_service_t, depth: Int) -> String? {
        if let name = IORegistry.property(service, "BSD Name", as: String.self) { return name }
        guard depth > 0 else { return nil }
        var found: String?
        for child in IORegistry.children(service) {
            if found == nil { found = bsdName(below: child, depth: depth - 1) }
            IOObjectRelease(child)
        }
        return found
    }
}
