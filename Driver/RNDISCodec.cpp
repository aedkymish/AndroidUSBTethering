//
//  RNDISCodec.cpp
//  AndroidRNDISDriver
//

#include "RNDISCodec.hpp"

#include <string.h>

namespace rndis {

namespace {

size_t writeHeader(uint8_t *out, size_t capacity, size_t length, uint32_t type) {
    if (out == nullptr || capacity < length) {
        return 0;
    }
    memset(out, 0, length);
    writeLE32(out + 0, type);
    writeLE32(out + 4, (uint32_t)length);
    return length;
}

size_t buildOIDRequest(uint8_t *out, size_t capacity, uint32_t type, uint32_t requestID,
                       uint32_t oid, const uint8_t *value, uint32_t valueLength) {
    const size_t length = 28 + valueLength;
    if (writeHeader(out, capacity, length, type) == 0) {
        return 0;
    }
    writeLE32(out + 8, requestID);
    writeLE32(out + 12, oid);
    writeLE32(out + 16, valueLength);
    writeLE32(out + 20, valueLength ? 20 : 0); // offset is relative to RequestID (byte 8)
    writeLE32(out + 24, 0);                    // DeviceVcHandle
    if (valueLength) {
        memcpy(out + 28, value, valueLength);
    }
    return length;
}

} // namespace

size_t buildInitialize(uint8_t *out, size_t capacity, uint32_t requestID, uint32_t maxTransferSize) {
    if (writeHeader(out, capacity, 24, kInitializeMsg) == 0) {
        return 0;
    }
    writeLE32(out + 8, requestID);
    writeLE32(out + 12, 1); // major version
    writeLE32(out + 16, 0); // minor version
    writeLE32(out + 20, maxTransferSize);
    return 24;
}

size_t buildQuery(uint8_t *out, size_t capacity, uint32_t requestID, uint32_t oid) {
    return buildOIDRequest(out, capacity, kQueryMsg, requestID, oid, nullptr, 0);
}

size_t buildSet(uint8_t *out, size_t capacity, uint32_t requestID, uint32_t oid,
                const uint8_t *value, uint32_t valueLength) {
    return buildOIDRequest(out, capacity, kSetMsg, requestID, oid, value, valueLength);
}

size_t buildKeepAliveComplete(uint8_t *out, size_t capacity, uint32_t requestID) {
    if (writeHeader(out, capacity, 16, kKeepAliveCmplt) == 0) {
        return 0;
    }
    writeLE32(out + 8, requestID);
    writeLE32(out + 12, kStatusSuccess);
    return 16;
}

size_t buildHalt(uint8_t *out, size_t capacity, uint32_t requestID) {
    if (writeHeader(out, capacity, 12, kHaltMsg) == 0) {
        return 0;
    }
    writeLE32(out + 8, requestID);
    return 12;
}

bool parseControl(const uint8_t *data, size_t length, ControlMessage *out) {
    if (data == nullptr || out == nullptr || length < 12) {
        return false;
    }
    memset(out, 0, sizeof(*out));
    out->type = readLE32(data);
    const uint32_t messageLength = readLE32(data + 4);
    if (messageLength < 12 || messageLength > length) {
        return false;
    }
    switch (out->type) {
    case kInitializeCmplt:
        if (messageLength < 40) {
            return false;
        }
        out->requestID = readLE32(data + 8);
        out->status = readLE32(data + 12);
        out->maxTransferSize = readLE32(data + 36);
        return true;
    case kQueryCmplt: {
        if (messageLength < 24) {
            return false;
        }
        out->requestID = readLE32(data + 8);
        out->status = readLE32(data + 12);
        const uint32_t bufferLength = readLE32(data + 16);
        const uint32_t bufferOffset = readLE32(data + 20);
        if (bufferLength) {
            const uint64_t start = 8ull + bufferOffset;
            if (start + bufferLength > messageLength) {
                return false;
            }
            out->buffer = data + start;
            out->bufferLength = bufferLength;
        }
        return true;
    }
    case kSetCmplt:
    case kKeepAliveCmplt:
        if (messageLength < 16) {
            return false;
        }
        out->requestID = readLE32(data + 8);
        out->status = readLE32(data + 12);
        return true;
    case kKeepAliveMsg:
        out->requestID = readLE32(data + 8);
        return true;
    case kIndicateStatusMsg:
        out->status = readLE32(data + 8);
        return true;
    default:
        return true; // known framing, unhandled type: caller ignores it
    }
}

size_t wrapPacket(uint8_t *out, size_t capacity, const uint8_t *frame, size_t frameLength) {
    const size_t length = kPacketHeaderLength + frameLength;
    if (frame == nullptr || writeHeader(out, capacity, length, kPacketMsg) == 0) {
        return 0;
    }
    writeLE32(out + 8, (uint32_t)(kPacketHeaderLength - 8)); // DataOffset, relative to byte 8
    writeLE32(out + 12, (uint32_t)frameLength);
    memcpy(out + kPacketHeaderLength, frame, frameLength);
    return length;
}

PacketIterator::PacketIterator(const uint8_t *data, size_t length)
    : data_(data), length_(data ? length : 0), cursor_(0) {}

bool PacketIterator::next(const uint8_t **frame, size_t *frameLength) {
    while (cursor_ + 16 <= length_) {
        const uint8_t *message = data_ + cursor_;
        const uint32_t type = readLE32(message);
        const uint32_t messageLength = readLE32(message + 4);
        if (type == 0 && messageLength == 0) {
            return false; // zero padding
        }
        if (type != kPacketMsg || messageLength < kPacketHeaderLength ||
            cursor_ + messageLength > length_) {
            return false;
        }
        const uint64_t dataOffset = 8ull + readLE32(message + 8);
        const uint32_t dataLength = readLE32(message + 12);
        cursor_ += messageLength;
        if (dataOffset + dataLength > messageLength || dataLength == 0) {
            continue;
        }
        *frame = message + dataOffset;
        *frameLength = dataLength;
        return true;
    }
    return false;
}

bool findDataInterface(const uint8_t *configuration, size_t length, uint8_t controlInterface,
                       DataInterfaceInfo *out) {
    constexpr uint8_t kInterfaceDescriptor = 0x04;
    constexpr uint8_t kEndpointDescriptor = 0x05;
    constexpr uint8_t kCDCDataClass = 0x0A;
    constexpr uint8_t kBulk = 0x02;

    if (configuration == nullptr || out == nullptr) {
        return false;
    }
    bool inCandidate = false;
    DataInterfaceInfo candidate = {};
    size_t cursor = 0;
    while (cursor + 2 <= length) {
        const uint8_t descriptorLength = configuration[cursor];
        const uint8_t descriptorType = configuration[cursor + 1];
        if (descriptorLength < 2 || cursor + descriptorLength > length) {
            break;
        }
        const uint8_t *d = configuration + cursor;
        if (descriptorType == kInterfaceDescriptor && descriptorLength >= 9) {
            if (inCandidate && candidate.bulkInAddress && candidate.bulkOutAddress) {
                *out = candidate;
                return true;
            }
            inCandidate = d[2] > controlInterface && d[5] == kCDCDataClass;
            candidate = {};
            candidate.interfaceNumber = d[2];
        } else if (descriptorType == kEndpointDescriptor && descriptorLength >= 7 && inCandidate &&
                   (d[3] & 0x03) == kBulk) {
            if (d[2] & 0x80) {
                candidate.bulkInAddress = d[2];
                candidate.bulkInMaxPacket = readLE16(d + 4);
            } else {
                candidate.bulkOutAddress = d[2];
            }
        }
        cursor += descriptorLength;
    }
    if (inCandidate && candidate.bulkInAddress && candidate.bulkOutAddress) {
        *out = candidate;
        return true;
    }
    return false;
}

} // namespace rndis
