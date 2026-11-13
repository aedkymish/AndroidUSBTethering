import Foundation

/// The USB networking function an Android phone exposes while USB tethering is on.
public enum TetheringProtocol: String, Codable {
    /// Microsoft RNDIS — needs this app's user-space driver on macOS.
    case rndis
    /// CDC-NCM — supported natively by macOS; the app only reports it.
    case ncm
}

/// Model describing an attached Android phone with tethering enabled.
public struct AndroidDevice: Hashable, Codable, Identifiable {
    /// IORegistry entry ID of the communication (control) interface.
    public let id: UInt64
    public let vendorID: UInt16
    public let productID: UInt16
    public let name: String
    public let serialNumber: String?
    public let tetheringProtocol: TetheringProtocol
    public let controlInterfaceNumber: UInt8

    public init(id: UInt64, vendorID: UInt16, productID: UInt16, name: String,
                serialNumber: String?, tetheringProtocol: TetheringProtocol, controlInterfaceNumber: UInt8) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.serialNumber = serialNumber
        self.tetheringProtocol = tetheringProtocol
        self.controlInterfaceNumber = controlInterfaceNumber
    }

    public var displayName: String {
        String(format: "%@ (%04x:%04x)", name, vendorID, productID)
    }
}
