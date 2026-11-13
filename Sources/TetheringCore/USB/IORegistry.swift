import Foundation
import IOKit

/// Small helpers around the IORegistry C API.
enum IORegistry {
    static func property<T>(_ service: io_service_t, _ key: String, as _: T.Type = T.self) -> T? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? T
    }

    static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        property(service, key, as: NSNumber.self)?.intValue
    }

    static func entryID(_ service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }

    /// Parent entry in the IOService plane (caller must release).
    static func parent(_ service: io_service_t) -> io_service_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        return parent
    }

    /// Children in the IOService plane (caller must release each).
    static func children(_ service: io_service_t) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    static func drain(_ iterator: io_iterator_t) -> [io_service_t] {
        var result: [io_service_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            result.append(entry)
        }
        return result
    }
}
