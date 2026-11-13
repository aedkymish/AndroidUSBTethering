import Foundation

/// Errors raised while decoding binary wire formats.
public enum DecodingError: Error, Equatable {
    case truncated(expected: Int, actual: Int)
    case invalidValue(String)
}

/// Appends fixed-width integers to a `Data` buffer in a chosen byte order.
public struct ByteWriter {
    public private(set) var data = Data()

    public init(capacity: Int = 0) {
        data.reserveCapacity(capacity)
    }

    public mutating func writeLE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeBE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func write(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    public mutating func writeZeros(_ count: Int) {
        data.append(contentsOf: [UInt8](repeating: 0, count: count))
    }
}

/// Bounds-checked reads of fixed-width integers from a byte buffer.
public struct ByteReader {
    public let bytes: [UInt8]

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var count: Int { bytes.count }

    public func require(_ length: Int) throws {
        guard bytes.count >= length else {
            throw DecodingError.truncated(expected: length, actual: bytes.count)
        }
    }

    public func readLE<T: FixedWidthInteger>(_: T.Type = T.self, at offset: Int) throws -> T {
        let size = MemoryLayout<T>.size
        try require(offset + size)
        var value: T = 0
        for index in 0..<size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        return value
    }

    public func readBE<T: FixedWidthInteger>(_: T.Type = T.self, at offset: Int) throws -> T {
        let size = MemoryLayout<T>.size
        try require(offset + size)
        var value: T = 0
        for index in 0..<size {
            value = (value << 8) | T(bytes[offset + index])
        }
        return value
    }

    public func slice(_ offset: Int, _ length: Int) throws -> [UInt8] {
        try require(offset + length)
        return Array(bytes[offset..<(offset + length)])
    }
}
