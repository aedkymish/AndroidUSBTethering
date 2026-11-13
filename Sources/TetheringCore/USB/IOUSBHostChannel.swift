import Foundation
import IOKit
import IOUSBHost

public enum USBChannelError: Error, LocalizedError {
    case dataInterfaceNotFound
    case endpointsNotFound
    case interfaceOpenFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .dataInterfaceNotFound: return "The RNDIS data interface was not found on the device."
        case .endpointsNotFound: return "The RNDIS bulk endpoints were not found."
        case let .interfaceOpenFailed(error): return "Could not open the USB interface: \(error.localizedDescription)"
        }
    }
}

/// `RNDISUSBChannel` backed by the user-space IOUSBHost framework.
///
/// The synchronous IOUSBHost calls are `NS_REFINED_FOR_SWIFT`, so Swift sees them with a `__` prefix.
public final class IOUSBHostChannel: RNDISUSBChannel {
    private let controlInterface: IOUSBHostInterface
    private let dataInterface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let controlInterfaceNumber: UInt16
    private let ioQueue = DispatchQueue(label: "AndroidUSBTethering.usb.io")
    private var reading = false
    private let lock = NSLock()

    public static let controlTimeout: TimeInterval = 5
    public static let bulkTimeout: TimeInterval = 5

    /// - Parameter controlService: the RNDIS communication interface (`IOUSBHostInterface`).
    public init(controlService: io_service_t) throws {
        do {
            controlInterface = try IOUSBHostInterface(__ioService: controlService, options: [],
                                                      queue: nil, interestHandler: nil)
        } catch {
            throw USBChannelError.interfaceOpenFailed(error)
        }
        controlInterfaceNumber = UInt16(IORegistry.intProperty(controlService, "bInterfaceNumber") ?? 0)

        let configuration = Self.configurationBytes(of: controlInterface)
        let interfaces = USBDescriptorParser.interfaces(inConfiguration: configuration)
        guard let dataInfo = USBDescriptorParser.dataInterface(forControl: UInt8(controlInterfaceNumber), in: interfaces),
              let inInfo = dataInfo.bulkIn, let outInfo = dataInfo.bulkOut else {
            controlInterface.destroy()
            throw USBChannelError.endpointsNotFound
        }
        guard let dataService = Self.siblingInterface(of: controlService, number: Int(dataInfo.number)) else {
            controlInterface.destroy()
            throw USBChannelError.dataInterfaceNotFound
        }
        defer { IOObjectRelease(dataService) }

        do {
            dataInterface = try IOUSBHostInterface(__ioService: dataService, options: [],
                                                   queue: nil, interestHandler: nil)
            bulkIn = try dataInterface.copyPipe(withAddress: Int(inInfo.address))
            bulkOut = try dataInterface.copyPipe(withAddress: Int(outInfo.address))
        } catch {
            controlInterface.destroy()
            throw USBChannelError.interfaceOpenFailed(error)
        }
    }

    public func sendEncapsulatedCommand(_ message: Data) throws {
        let request = IOUSBDeviceRequest(bmRequestType: CDCRequest.typeOut,
                                         bRequest: CDCRequest.sendEncapsulatedCommand,
                                         wValue: 0, wIndex: controlInterfaceNumber,
                                         wLength: UInt16(message.count))
        let buffer = NSMutableData(data: message)
        var transferred = 0
        try controlInterface.__sendDeviceRequest(request, data: buffer, bytesTransferred: &transferred,
                                               completionTimeout: Self.controlTimeout)
    }

    public func getEncapsulatedResponse(maxLength: Int) throws -> Data {
        let request = IOUSBDeviceRequest(bmRequestType: CDCRequest.typeIn,
                                         bRequest: CDCRequest.getEncapsulatedResponse,
                                         wValue: 0, wIndex: controlInterfaceNumber,
                                         wLength: UInt16(maxLength))
        let buffer = NSMutableData(length: maxLength) ?? NSMutableData()
        var transferred = 0
        try controlInterface.__sendDeviceRequest(request, data: buffer, bytesTransferred: &transferred,
                                               completionTimeout: Self.controlTimeout)
        return Data(bytes: buffer.bytes, count: transferred)
    }

    public func writeBulk(_ data: Data) throws {
        let buffer = NSMutableData(data: data)
        var transferred = 0
        try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred,
                                  completionTimeout: Self.bulkTimeout)
    }

    public func startBulkReading(transferSize: Int, handler: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        reading = true
        lock.unlock()
        let thread = Thread { [weak self] in
            let buffer = NSMutableData(length: transferSize) ?? NSMutableData()
            while let self, self.isReading {
                var transferred = 0
                do {
                    // A timeout of 0 waits indefinitely; close() destroys the pipe to unblock.
                    try self.bulkIn.__sendIORequest(with: buffer, bytesTransferred: &transferred,
                                                  completionTimeout: 0)
                    if transferred > 0 {
                        handler(.success(Data(bytes: buffer.bytes, count: transferred)))
                    }
                } catch {
                    if self.isReading { handler(.failure(error)) }
                    return
                }
            }
        }
        thread.name = "AndroidUSBTethering.bulk-in"
        thread.qualityOfService = QualityOfService.userInitiated
        thread.start()
    }

    public func close() {
        lock.lock()
        reading = false
        lock.unlock()
        dataInterface.destroy()
        controlInterface.destroy()
    }

    // MARK: Private

    private var isReading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    private static func configurationBytes(of interface: IOUSBHostInterface) -> [UInt8] {
        let raw = UnsafeRawPointer(interface.configurationDescriptor)
        let total = Int(raw.load(fromByteOffset: 2, as: UInt8.self))
            | Int(raw.load(fromByteOffset: 3, as: UInt8.self)) << 8
        return [UInt8](UnsafeRawBufferPointer(start: raw, count: total))
    }

    private static func siblingInterface(of service: io_service_t, number: Int) -> io_service_t? {
        guard let device = IORegistry.parent(service) else { return nil }
        defer { IOObjectRelease(device) }
        var match: io_service_t?
        for child in IORegistry.children(device) {
            if match == nil, IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               IORegistry.intProperty(child, "bInterfaceNumber") == number {
                match = child
            } else {
                IOObjectRelease(child)
            }
        }
        return match
    }
}
