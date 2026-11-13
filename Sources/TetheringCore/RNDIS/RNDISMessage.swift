import Foundation

/// Messages exchanged with an RNDIS device. Encoding is little-endian per MS-RNDIS.
public enum RNDISMessage: Equatable {
    case initialize(requestID: UInt32, maxTransferSize: UInt32)
    case initializeComplete(InitializeComplete)
    case query(requestID: UInt32, oid: UInt32, buffer: Data)
    case queryComplete(requestID: UInt32, status: UInt32, buffer: Data)
    case set(requestID: UInt32, oid: UInt32, buffer: Data)
    case setComplete(requestID: UInt32, status: UInt32)
    case keepAlive(requestID: UInt32)
    case keepAliveComplete(requestID: UInt32, status: UInt32)
    case reset
    case resetComplete(status: UInt32)
    case indicateStatus(status: UInt32)
    case halt(requestID: UInt32)

    public struct InitializeComplete: Equatable {
        public var requestID: UInt32
        public var status: UInt32
        public var majorVersion: UInt32
        public var minorVersion: UInt32
        public var deviceFlags: UInt32
        public var medium: UInt32
        public var maxPacketsPerTransfer: UInt32
        public var maxTransferSize: UInt32
        public var packetAlignmentFactor: UInt32
    }

    /// Request ID carried by the message, if any.
    public var requestID: UInt32? {
        switch self {
        case let .initialize(id, _), let .query(id, _, _), let .queryComplete(id, _, _),
             let .set(id, _, _), let .setComplete(id, _), let .keepAlive(id),
             let .keepAliveComplete(id, _), let .halt(id):
            return id
        case let .initializeComplete(body):
            return body.requestID
        case .reset, .resetComplete, .indicateStatus:
            return nil
        }
    }

    // MARK: Encoding

    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .initialize(requestID, maxTransferSize):
            w.writeLE(RNDISMessageType.initialize.rawValue)
            w.writeLE(UInt32(24))
            w.writeLE(requestID)
            w.writeLE(UInt32(1)) // major version
            w.writeLE(UInt32(0)) // minor version
            w.writeLE(maxTransferSize)
        case let .query(requestID, oid, buffer):
            Self.writeOIDRequest(&w, type: .query, requestID: requestID, oid: oid, buffer: buffer)
        case let .set(requestID, oid, buffer):
            Self.writeOIDRequest(&w, type: .set, requestID: requestID, oid: oid, buffer: buffer)
        case let .keepAlive(requestID):
            w.writeLE(RNDISMessageType.keepAlive.rawValue)
            w.writeLE(UInt32(12))
            w.writeLE(requestID)
        case let .keepAliveComplete(requestID, status):
            w.writeLE(RNDISMessageType.keepAliveComplete.rawValue)
            w.writeLE(UInt32(16))
            w.writeLE(requestID)
            w.writeLE(status)
        case let .halt(requestID):
            w.writeLE(RNDISMessageType.halt.rawValue)
            w.writeLE(UInt32(12))
            w.writeLE(requestID)
        case .reset:
            w.writeLE(RNDISMessageType.reset.rawValue)
            w.writeLE(UInt32(12))
            w.writeLE(UInt32(0))
        case let .setComplete(requestID, status):
            w.writeLE(RNDISMessageType.setComplete.rawValue)
            w.writeLE(UInt32(16))
            w.writeLE(requestID)
            w.writeLE(status)
        case let .queryComplete(requestID, status, buffer):
            w.writeLE(RNDISMessageType.queryComplete.rawValue)
            w.writeLE(UInt32(24 + buffer.count))
            w.writeLE(requestID)
            w.writeLE(status)
            w.writeLE(UInt32(buffer.count))
            w.writeLE(UInt32(buffer.isEmpty ? 0 : 16)) // offset from RequestID
            w.write(buffer)
        case let .initializeComplete(body):
            w.writeLE(RNDISMessageType.initializeComplete.rawValue)
            w.writeLE(UInt32(52))
            for field in [body.requestID, body.status, body.majorVersion, body.minorVersion,
                          body.deviceFlags, body.medium, body.maxPacketsPerTransfer,
                          body.maxTransferSize, body.packetAlignmentFactor, 0, 0] {
                w.writeLE(field)
            }
        case let .resetComplete(status):
            w.writeLE(RNDISMessageType.resetComplete.rawValue)
            w.writeLE(UInt32(16))
            w.writeLE(status)
            w.writeLE(UInt32(0))
        case let .indicateStatus(status):
            w.writeLE(RNDISMessageType.indicateStatus.rawValue)
            w.writeLE(UInt32(20))
            w.writeLE(status)
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
        }
        return w.data
    }

    private static func writeOIDRequest(_ w: inout ByteWriter, type: RNDISMessageType,
                                        requestID: UInt32, oid: UInt32, buffer: Data) {
        w.writeLE(type.rawValue)
        w.writeLE(UInt32(28 + buffer.count))
        w.writeLE(requestID)
        w.writeLE(oid)
        w.writeLE(UInt32(buffer.count))
        w.writeLE(UInt32(buffer.isEmpty ? 0 : 20)) // offset from RequestID
        w.writeLE(UInt32(0))                       // DeviceVcHandle
        w.write(buffer)
    }

    // MARK: Decoding

    public init(decoding data: Data) throws {
        let r = ByteReader(data)
        let rawType: UInt32 = try r.readLE(at: 0)
        guard let type = RNDISMessageType(rawValue: rawType) else {
            throw DecodingError.invalidValue(String(format: "RNDIS message type 0x%08x", rawType))
        }
        switch type {
        case .initialize:
            self = .initialize(requestID: try r.readLE(at: 8), maxTransferSize: try r.readLE(at: 20))
        case .initializeComplete:
            self = .initializeComplete(InitializeComplete(
                requestID: try r.readLE(at: 8),
                status: try r.readLE(at: 12),
                majorVersion: try r.readLE(at: 16),
                minorVersion: try r.readLE(at: 20),
                deviceFlags: try r.readLE(at: 24),
                medium: try r.readLE(at: 28),
                maxPacketsPerTransfer: try r.readLE(at: 32),
                maxTransferSize: try r.readLE(at: 36),
                packetAlignmentFactor: try r.readLE(at: 40)))
        case .query, .set:
            let requestID: UInt32 = try r.readLE(at: 8)
            let oid: UInt32 = try r.readLE(at: 12)
            let length = Int(try r.readLE(UInt32.self, at: 16))
            let offset = Int(try r.readLE(UInt32.self, at: 20))
            let buffer = length == 0 ? Data() : Data(try r.slice(8 + offset, length))
            self = type == .query
                ? .query(requestID: requestID, oid: oid, buffer: buffer)
                : .set(requestID: requestID, oid: oid, buffer: buffer)
        case .queryComplete:
            let length = Int(try r.readLE(UInt32.self, at: 16))
            let offset = Int(try r.readLE(UInt32.self, at: 20))
            let buffer = length == 0 ? Data() : Data(try r.slice(8 + offset, length))
            self = .queryComplete(requestID: try r.readLE(at: 8), status: try r.readLE(at: 12), buffer: buffer)
        case .setComplete:
            self = .setComplete(requestID: try r.readLE(at: 8), status: try r.readLE(at: 12))
        case .keepAlive:
            self = .keepAlive(requestID: try r.readLE(at: 8))
        case .keepAliveComplete:
            self = .keepAliveComplete(requestID: try r.readLE(at: 8), status: try r.readLE(at: 12))
        case .reset:
            self = .reset
        case .resetComplete:
            self = .resetComplete(status: try r.readLE(at: 8))
        case .indicateStatus:
            self = .indicateStatus(status: try r.readLE(at: 8))
        case .halt:
            self = .halt(requestID: try r.readLE(at: 8))
        case .packet:
            throw DecodingError.invalidValue("PACKET_MSG is a data-plane message; use RNDISPacketCodec")
        }
    }
}

/// Wraps and unwraps Ethernet frames in `REMOTE_NDIS_PACKET_MSG` envelopes.
public enum RNDISPacketCodec {
    public static let headerLength = 44

    public static func wrap(_ frame: Data) -> Data {
        var w = ByteWriter(capacity: headerLength + frame.count)
        w.writeLE(RNDISMessageType.packet.rawValue)
        w.writeLE(UInt32(headerLength + frame.count))
        w.writeLE(UInt32(headerLength - 8)) // DataOffset, relative to this field
        w.writeLE(UInt32(frame.count))
        w.writeZeros(headerLength - 16)     // OOB, per-packet info, VcHandle, reserved
        w.write(frame)
        return w.data
    }

    /// Splits a bulk-IN transfer, which may contain several concatenated PACKET_MSGs.
    public static func unwrap(_ transfer: Data) throws -> [Data] {
        let r = ByteReader(transfer)
        var frames: [Data] = []
        var cursor = 0
        while cursor + 16 <= r.count {
            let type: UInt32 = try r.readLE(at: cursor)
            let messageLength = Int(try r.readLE(UInt32.self, at: cursor + 4))
            if type == 0 && messageLength == 0 { break } // zero padding
            guard type == RNDISMessageType.packet.rawValue else {
                throw DecodingError.invalidValue(String(format: "unexpected data message 0x%08x", type))
            }
            guard messageLength >= headerLength, cursor + messageLength <= r.count else {
                throw DecodingError.truncated(expected: cursor + messageLength, actual: r.count)
            }
            let dataOffset = Int(try r.readLE(UInt32.self, at: cursor + 8))
            let dataLength = Int(try r.readLE(UInt32.self, at: cursor + 12))
            let start = cursor + 8 + dataOffset
            guard start + dataLength <= cursor + messageLength else {
                throw DecodingError.invalidValue("PACKET_MSG data overruns message")
            }
            frames.append(Data(r.bytes[start..<(start + dataLength)]))
            cursor += messageLength
        }
        return frames
    }
}
