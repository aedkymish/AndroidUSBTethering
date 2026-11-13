import Foundation

/// Raw USB I/O needed by `RNDISTransport`. Abstracted so the protocol logic can be
/// unit-tested with a mock and the backend swapped (IOUSBHost today, DriverKit later).
public protocol RNDISUSBChannel: AnyObject {
    /// CDC SEND_ENCAPSULATED_COMMAND on the control interface.
    func sendEncapsulatedCommand(_ message: Data) throws
    /// CDC GET_ENCAPSULATED_RESPONSE; returns empty data when nothing is pending.
    func getEncapsulatedResponse(maxLength: Int) throws -> Data
    /// Synchronous bulk-OUT write.
    func writeBulk(_ data: Data) throws
    /// Starts a background bulk-IN read loop. The handler is called for every completed
    /// transfer, or once with an error when the loop stops.
    func startBulkReading(transferSize: Int, handler: @escaping (Result<Data, Error>) -> Void)
    /// Stops I/O and releases the USB interfaces.
    func close()
}
