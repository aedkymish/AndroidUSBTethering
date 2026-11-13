import Foundation
import IOKit

/// Observes IOKit for Android tethering interfaces (RNDIS and NCM) being attached or removed.
public final class USBDeviceMonitor {
    public var onAttach: ((AndroidDevice) -> Void)?
    public var onDetach: ((UInt64) -> Void)?

    private let queue: DispatchQueue
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    public private(set) var devices: [UInt64: AndroidDevice] = [:]

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { stop() }

    public func start() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let codes: [(TetheringProtocol, (cls: UInt8, subclass: UInt8, proto: UInt8))] = [
            (.rndis, USBClassCode.rndisWireless),
            (.rndis, USBClassCode.rndisCDC),
            (.ncm, USBClassCode.ncm),
        ]
        for (_, code) in codes {
            register(port: port, code: code, type: kIOFirstMatchNotification, callback: Self.matchedCallback)
            register(port: port, code: code, type: kIOTerminatedNotification, callback: Self.terminatedCallback)
        }
    }

    public func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    /// Returns a retained io_service_t for the interface, or nil if it has gone away.
    public func service(for device: AndroidDevice) -> io_service_t? {
        guard let matching = IORegistryEntryIDMatching(device.id) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return service == 0 ? nil : service
    }

    // MARK: Private

    private static let matchedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue().handleMatched(iterator)
    }

    private static let terminatedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue().handleTerminated(iterator)
    }

    private func register(port: IONotificationPortRef, code: (cls: UInt8, subclass: UInt8, proto: UInt8),
                          type: String, callback: IOServiceMatchingCallback) {
        let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        matching["bInterfaceClass"] = NSNumber(value: code.cls)
        matching["bInterfaceSubClass"] = NSNumber(value: code.subclass)
        matching["bInterfaceProtocol"] = NSNumber(value: code.proto)

        var iterator: io_iterator_t = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, type, matching as CFDictionary, callback, refcon, &iterator)
        guard result == KERN_SUCCESS else { return }
        iterators.append(iterator)
        // Drain once to arm the notification and pick up already-attached devices.
        callback(refcon, iterator)
    }

    private func handleMatched(_ iterator: io_iterator_t) {
        for service in IORegistry.drain(iterator) {
            defer { IOObjectRelease(service) }
            guard let device = makeDevice(from: service) else { continue }
            devices[device.id] = device
            onAttach?(device)
        }
    }

    private func handleTerminated(_ iterator: io_iterator_t) {
        for service in IORegistry.drain(iterator) {
            defer { IOObjectRelease(service) }
            let id = IORegistry.entryID(service)
            if devices.removeValue(forKey: id) != nil {
                onDetach?(id)
            }
        }
    }

    private func makeDevice(from service: io_service_t) -> AndroidDevice? {
        guard let cls = IORegistry.intProperty(service, "bInterfaceClass"),
              let sub = IORegistry.intProperty(service, "bInterfaceSubClass"),
              let number = IORegistry.intProperty(service, "bInterfaceNumber") else { return nil }
        let proto: TetheringProtocol =
            (UInt8(cls), UInt8(sub)) == (USBClassCode.ncm.cls, USBClassCode.ncm.subclass) ? .ncm : .rndis

        var vendor = 0, product = 0
        var name = "Android device"
        var serial: String?
        if let parent = IORegistry.parent(service) {
            defer { IOObjectRelease(parent) }
            vendor = IORegistry.intProperty(parent, "idVendor") ?? 0
            product = IORegistry.intProperty(parent, "idProduct") ?? 0
            name = IORegistry.property(parent, "USB Product Name", as: String.self)
                ?? IORegistry.property(parent, "kUSBProductString", as: String.self) ?? name
            serial = IORegistry.property(parent, "USB Serial Number", as: String.self)
                ?? IORegistry.property(parent, "kUSBSerialNumberString", as: String.self)
        }
        return AndroidDevice(id: IORegistry.entryID(service),
                             vendorID: UInt16(truncatingIfNeeded: vendor),
                             productID: UInt16(truncatingIfNeeded: product),
                             name: name, serialNumber: serial,
                             tetheringProtocol: proto,
                             controlInterfaceNumber: UInt8(truncatingIfNeeded: number))
    }
}
