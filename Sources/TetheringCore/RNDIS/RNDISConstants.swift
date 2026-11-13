import Foundation

/// RNDIS control and data message types (MS-RNDIS §2.2).
public enum RNDISMessageType: UInt32 {
    case packet = 0x0000_0001
    case initialize = 0x0000_0002
    case initializeComplete = 0x8000_0002
    case halt = 0x0000_0003
    case query = 0x0000_0004
    case queryComplete = 0x8000_0004
    case set = 0x0000_0005
    case setComplete = 0x8000_0005
    case reset = 0x0000_0006
    case resetComplete = 0x8000_0006
    case indicateStatus = 0x0000_0007
    case keepAlive = 0x0000_0008
    case keepAliveComplete = 0x8000_0008
}

/// NDIS object identifiers used during link bring-up.
public enum RNDISOID: UInt32 {
    case genMaximumFrameSize = 0x0001_0106
    case genCurrentPacketFilter = 0x0001_010E
    case genMediaConnectStatus = 0x0001_0114
    case permanentAddress = 0x0101_0101
    case currentAddress = 0x0101_0102
}

/// NDIS packet-filter bits for `OID_GEN_CURRENT_PACKET_FILTER`.
public struct RNDISPacketFilter: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let directed = RNDISPacketFilter(rawValue: 0x01)
    public static let multicast = RNDISPacketFilter(rawValue: 0x02)
    public static let allMulticast = RNDISPacketFilter(rawValue: 0x04)
    public static let broadcast = RNDISPacketFilter(rawValue: 0x08)
    public static let promiscuous = RNDISPacketFilter(rawValue: 0x20)

    public static let standard: RNDISPacketFilter = [.directed, .broadcast, .allMulticast]
}

/// RNDIS status codes.
public enum RNDISStatus {
    public static let success: UInt32 = 0x0000_0000
    public static let failure: UInt32 = 0xC000_0001
    public static let mediaConnect: UInt32 = 0x4001_000B
    public static let mediaDisconnect: UInt32 = 0x4001_000C
}

/// USB class codes that identify the RNDIS / NCM function on Android phones.
public enum USBClassCode {
    /// Wireless Controller / RF / RNDIS — used by most Android devices.
    public static let rndisWireless = (cls: UInt8(0xE0), subclass: UInt8(0x01), proto: UInt8(0x03))
    /// CDC Communications / ACM / vendor-specific — RNDIS variant used by some devices.
    public static let rndisCDC = (cls: UInt8(0x02), subclass: UInt8(0x02), proto: UInt8(0xFF))
    /// CDC Network Control Model — handled natively by macOS.
    public static let ncm = (cls: UInt8(0x02), subclass: UInt8(0x0D), proto: UInt8(0x00))
    /// CDC Data interface carrying the bulk endpoints.
    public static let cdcData: UInt8 = 0x0A
}

/// CDC class-specific control requests used by RNDIS.
public enum CDCRequest {
    public static let sendEncapsulatedCommand: UInt8 = 0x00
    public static let getEncapsulatedResponse: UInt8 = 0x01
    /// Host-to-device | Class | Interface
    public static let typeOut: UInt8 = 0x21
    /// Device-to-host | Class | Interface
    public static let typeIn: UInt8 = 0xA1
}
