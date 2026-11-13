import Foundation

/// A parsed USB endpoint descriptor.
public struct USBEndpointInfo: Equatable {
    public enum TransferType: UInt8 {
        case control = 0, isochronous = 1, bulk = 2, interrupt = 3
    }

    public let address: UInt8
    public let transferType: TransferType
    public let maxPacketSize: UInt16

    public var isInput: Bool { address & 0x80 != 0 }
}

/// A parsed USB interface descriptor (one alternate setting) and its endpoints.
public struct USBInterfaceInfo: Equatable {
    public let number: UInt8
    public let alternateSetting: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8
    public var endpoints: [USBEndpointInfo]

    public func matches(_ code: (cls: UInt8, subclass: UInt8, proto: UInt8)) -> Bool {
        interfaceClass == code.cls && interfaceSubclass == code.subclass && interfaceProtocol == code.proto
    }

    public var bulkIn: USBEndpointInfo? { endpoints.first { $0.transferType == .bulk && $0.isInput } }
    public var bulkOut: USBEndpointInfo? { endpoints.first { $0.transferType == .bulk && !$0.isInput } }
}

/// Pure parser for a raw USB configuration descriptor blob (wTotalLength bytes).
public enum USBDescriptorParser {
    private static let interfaceType: UInt8 = 0x04
    private static let endpointType: UInt8 = 0x05

    public static func interfaces(inConfiguration bytes: [UInt8]) -> [USBInterfaceInfo] {
        var result: [USBInterfaceInfo] = []
        var cursor = 0
        while cursor + 2 <= bytes.count {
            let length = Int(bytes[cursor])
            guard length >= 2, cursor + length <= bytes.count else { break }
            let type = bytes[cursor + 1]
            if type == interfaceType, length >= 9 {
                result.append(USBInterfaceInfo(
                    number: bytes[cursor + 2],
                    alternateSetting: bytes[cursor + 3],
                    interfaceClass: bytes[cursor + 5],
                    interfaceSubclass: bytes[cursor + 6],
                    interfaceProtocol: bytes[cursor + 7],
                    endpoints: []))
            } else if type == endpointType, length >= 7, !result.isEmpty,
                      let transfer = USBEndpointInfo.TransferType(rawValue: bytes[cursor + 3] & 0x03) {
                result[result.count - 1].endpoints.append(USBEndpointInfo(
                    address: bytes[cursor + 2],
                    transferType: transfer,
                    maxPacketSize: UInt16(bytes[cursor + 4]) | UInt16(bytes[cursor + 5]) << 8))
            }
            cursor += length
        }
        return result
    }

    /// Finds the CDC Data interface that pairs with an RNDIS control interface:
    /// the first data-class interface after it that has both bulk endpoints.
    public static func dataInterface(forControl control: UInt8, in interfaces: [USBInterfaceInfo]) -> USBInterfaceInfo? {
        interfaces.first {
            $0.number > control && $0.interfaceClass == USBClassCode.cdcData
                && $0.bulkIn != nil && $0.bulkOut != nil
        }
    }
}
