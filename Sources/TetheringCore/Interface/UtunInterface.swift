import Darwin
import Foundation

public enum UtunError: Error, LocalizedError {
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .system(call, code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A kernel `utun` interface (layer 3). Requires root.
public final class UtunInterface: VirtualInterface {
    public private(set) var name = ""
    public var onPacket: ((Data) -> Void)?

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "AndroidUSBTethering.utun")
    private let commandRunner: CommandRunning

    // Constants from <sys/kern_control.h> and <net/if_utun.h>; spelled out because
    // the ioctl macro and some structs are not imported into Swift.
    private static let controlName = "com.apple.net.utun_control"
    private static let ctlIOCGInfo: UInt = 0xC064_4E03 // _IOWR('N', 3, struct ctl_info)
    private static let afSystem: Int32 = 32 // AF_SYSTEM / PF_SYSTEM
    private static let sysprotoControl: Int32 = 2
    private static let interfaceNameSize = 16 // IFNAMSIZ
    private static let afSysControl: UInt16 = 2
    private static let utunOptIfName: Int32 = 2
    private static let packetHeaderLength = 4

    public init(commandRunner: CommandRunning = ProcessCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func open() throws {
        fd = socket(Self.afSystem, SOCK_DGRAM, Self.sysprotoControl)
        guard fd >= 0 else { throw UtunError.system("socket", errno) }

        // struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; }
        var info = [UInt8](repeating: 0, count: 100)
        for (index, byte) in Self.controlName.utf8.enumerated() { info[4 + index] = byte }
        let ioctlResult = info.withUnsafeMutableBytes { ioctl(fd, Self.ctlIOCGInfo, $0.baseAddress!) }
        guard ioctlResult == 0 else { throw closeAndFail("ioctl(CTLIOCGINFO)") }
        let controlID = info.withUnsafeBytes { $0.load(as: UInt32.self) }

        // struct sockaddr_ctl { u_char sc_len; u_char sc_family; u_int16_t ss_sysaddr;
        //                       u_int32_t sc_id; u_int32_t sc_unit; u_int32_t sc_reserved[5]; }
        var address = [UInt8](repeating: 0, count: 32)
        address[0] = 32
        address[1] = UInt8(Self.afSystem)
        withUnsafeBytes(of: Self.afSysControl) { address.replaceSubrange(2..<4, with: $0) }
        withUnsafeBytes(of: controlID) { address.replaceSubrange(4..<8, with: $0) }
        // sc_unit = 0 lets the kernel pick the next free utunN.
        let connectResult = address.withUnsafeBytes {
            connect(fd, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), 32)
        }
        guard connectResult == 0 else { throw closeAndFail("connect(utun)") }

        var nameBuffer = [CChar](repeating: 0, count: Self.interfaceNameSize)
        var nameLength = socklen_t(nameBuffer.count)
        guard getsockopt(fd, Self.sysprotoControl, Self.utunOptIfName, &nameBuffer, &nameLength) == 0 else {
            throw closeAndFail("getsockopt(UTUN_OPT_IFNAME)")
        }
        name = String(cString: nameBuffer)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        startReading()
    }

    public func configure(with lease: DHCPLease) throws {
        var arguments = [name, "inet", lease.address.description, lease.router.description,
                         "netmask", lease.subnetMask.description]
        if let mtu = lease.mtu { arguments += ["mtu", String(mtu)] }
        arguments.append("up")
        try commandRunner.run("/sbin/ifconfig", arguments)
    }

    public func write(ipPacket: Data) throws {
        guard fd >= 0 else { return }
        var header = ByteWriter(capacity: Self.packetHeaderLength + ipPacket.count)
        header.writeBE(UInt32(AF_INET))
        header.write(ipPacket)
        let packet = header.data
        let written = packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, packet.count) }
        if written < 0 { throw UtunError.system("write(utun)", errno) }
    }

    public func close() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: Private

    private func closeAndFail(_ call: String) -> UtunError {
        let code = errno
        Darwin.close(fd)
        fd = -1
        return .system(call, code)
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let descriptor = fd
        source.setEventHandler { [weak self] in
            let capacity = 65_535 + Self.packetHeaderLength
            var buffer = [UInt8](repeating: 0, count: capacity)
            while true {
                let count = read(descriptor, &buffer, capacity)
                guard count > Self.packetHeaderLength else { break }
                let family = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])
                guard family == UInt32(AF_INET) else { continue } // IPv6 is not bridged yet
                self?.onPacket?(Data(buffer[Self.packetHeaderLength..<count]))
            }
        }
        source.resume()
        readSource = source
    }
}
