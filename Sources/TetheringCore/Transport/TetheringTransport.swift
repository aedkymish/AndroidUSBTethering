import Foundation

/// A link-layer (Ethernet) transport to the phone.
public protocol TetheringTransport: AnyObject {
    /// MAC address the host side of the link must use.
    var macAddress: MACAddress { get }
    /// Called for every Ethernet frame received from the phone.
    var onFrameReceived: ((Data) -> Void)? { get set }
    /// Called once when the link fails or the device disappears.
    var onDisconnect: ((Error?) -> Void)? { get set }

    /// Performs the protocol handshake. Blocks until the link is ready.
    func open() throws
    /// Sends one Ethernet frame to the phone.
    func send(frame: Data) throws
    func close()
}
