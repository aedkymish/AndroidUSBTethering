//
//  RNDISCodec.hpp
//  AndroidRNDISDriver
//
//  Portable RNDIS (MS-RNDIS) and USB descriptor helpers used by the DriverKit extension.
//  No DriverKit dependencies, so the logic is unit-tested on any platform (Driver/Tests).
//

#ifndef RNDISCodec_hpp
#define RNDISCodec_hpp

#include <stddef.h>
#include <stdint.h>

namespace rndis {

// Message types (MS-RNDIS §2.2)
constexpr uint32_t kPacketMsg            = 0x00000001;
constexpr uint32_t kInitializeMsg        = 0x00000002;
constexpr uint32_t kInitializeCmplt      = 0x80000002;
constexpr uint32_t kHaltMsg              = 0x00000003;
constexpr uint32_t kQueryMsg             = 0x00000004;
constexpr uint32_t kQueryCmplt           = 0x80000004;
constexpr uint32_t kSetMsg               = 0x00000005;
constexpr uint32_t kSetCmplt             = 0x80000005;
constexpr uint32_t kIndicateStatusMsg    = 0x00000007;
constexpr uint32_t kKeepAliveMsg         = 0x00000008;
constexpr uint32_t kKeepAliveCmplt       = 0x80000008;

constexpr uint32_t kStatusSuccess        = 0x00000000;

// Object identifiers
constexpr uint32_t kOidGenCurrentPacketFilter = 0x0001010E;
constexpr uint32_t kOid8023PermanentAddress   = 0x01010101;

// Packet filter: DIRECTED | ALL_MULTICAST | BROADCAST
constexpr uint32_t kPacketFilterStandard = 0x01 | 0x04 | 0x08;

// Sizes
constexpr size_t   kPacketHeaderLength   = 44;
constexpr size_t   kControlBufferSize    = 1025;
constexpr uint32_t kRequestedMaxTransfer = 16384;
constexpr size_t   kEthernetMaxFrame     = 1514;

// CDC class requests
constexpr uint8_t kRequestTypeOut              = 0x21;
constexpr uint8_t kRequestTypeIn               = 0xA1;
constexpr uint8_t kSendEncapsulatedCommand     = 0x00;
constexpr uint8_t kGetEncapsulatedResponse     = 0x01;

// ---- Control-plane encoders. Each returns the message length, or 0 if `capacity` is too small.

size_t buildInitialize(uint8_t *out, size_t capacity, uint32_t requestID, uint32_t maxTransferSize);
size_t buildQuery(uint8_t *out, size_t capacity, uint32_t requestID, uint32_t oid);
size_t buildSet(uint8_t *out, size_t capacity, uint32_t requestID, uint32_t oid,
                const uint8_t *value, uint32_t valueLength);
size_t buildKeepAliveComplete(uint8_t *out, size_t capacity, uint32_t requestID);
size_t buildHalt(uint8_t *out, size_t capacity, uint32_t requestID);

/// A decoded control message. `buffer` points into the input data.
struct ControlMessage {
    uint32_t type;
    uint32_t requestID;          // 0 for messages without one
    uint32_t status;
    uint32_t maxTransferSize;    // INITIALIZE_CMPLT only
    const uint8_t *buffer;       // QUERY_CMPLT only
    uint32_t bufferLength;
};

/// Decodes a control response. Returns false for malformed or truncated input.
bool parseControl(const uint8_t *data, size_t length, ControlMessage *out);

// ---- Data plane

/// Wraps an Ethernet frame in a REMOTE_NDIS_PACKET_MSG. Returns total length, or 0 on overflow.
size_t wrapPacket(uint8_t *out, size_t capacity, const uint8_t *frame, size_t frameLength);

/// Iterates the Ethernet frames inside one bulk-IN transfer (several PACKET_MSGs may be
/// concatenated, possibly followed by zero padding).
class PacketIterator {
public:
    PacketIterator(const uint8_t *data, size_t length);
    /// Returns false when there are no more (valid) frames.
    bool next(const uint8_t **frame, size_t *frameLength);
private:
    const uint8_t *data_;
    size_t length_;
    size_t cursor_;
};

// ---- USB descriptors

struct DataInterfaceInfo {
    uint8_t interfaceNumber;
    uint8_t bulkInAddress;
    uint8_t bulkOutAddress;
    uint16_t bulkInMaxPacket;
};

/// Finds the CDC Data interface (class 0x0A) paired with `controlInterface` in a raw
/// configuration descriptor: the first one after it that has bulk IN and bulk OUT endpoints.
bool findDataInterface(const uint8_t *configuration, size_t length, uint8_t controlInterface,
                       DataInterfaceInfo *out);

// ---- Little-endian helpers

inline uint32_t readLE32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

inline uint16_t readLE16(const uint8_t *p) {
    return (uint16_t)(p[0] | p[1] << 8);
}

inline void writeLE32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

} // namespace rndis

#endif /* RNDISCodec_hpp */
