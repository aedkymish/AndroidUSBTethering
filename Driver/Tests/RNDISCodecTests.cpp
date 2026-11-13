//
//  RNDISCodecTests.cpp
//  Host-side unit tests for the DriverKit RNDIS codec.
//  Build: c++ -std=c++17 -Wall -Wextra -I Driver Driver/RNDISCodec.cpp Driver/Tests/RNDISCodecTests.cpp
//

#include "RNDISCodec.hpp"

#include <stdio.h>
#include <string.h>
#include <vector>

static int failures = 0;

#define EXPECT(cond)                                                                    \
    do {                                                                                \
        if (!(cond)) {                                                                  \
            fprintf(stderr, "%s:%d: expectation failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                                 \
        }                                                                               \
    } while (0)

using namespace rndis;

static void testInitializeEncoding() {
    uint8_t buffer[64];
    EXPECT(buildInitialize(buffer, sizeof(buffer), 1, 0x4000) == 24);
    const uint8_t expected[24] = {2, 0, 0, 0, 24, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0};
    EXPECT(memcmp(buffer, expected, 24) == 0);
    EXPECT(buildInitialize(buffer, 10, 1, 0x4000) == 0);
}

static void testSetCarriesValueAtOffset20() {
    uint8_t buffer[64];
    uint8_t filter[4];
    writeLE32(filter, kPacketFilterStandard);
    EXPECT(buildSet(buffer, sizeof(buffer), 3, kOidGenCurrentPacketFilter, filter, 4) == 32);
    EXPECT(readLE32(buffer + 0) == kSetMsg);
    EXPECT(readLE32(buffer + 16) == 4);
    EXPECT(readLE32(buffer + 20) == 20);
    EXPECT(readLE32(buffer + 28) == 0x0D);
}

static void testParseQueryCompleteWithMAC() {
    uint8_t message[30] = {};
    writeLE32(message + 0, kQueryCmplt);
    writeLE32(message + 4, 30);
    writeLE32(message + 8, 7);
    writeLE32(message + 12, kStatusSuccess);
    writeLE32(message + 16, 6);
    writeLE32(message + 20, 16);
    const uint8_t mac[6] = {0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
    memcpy(message + 24, mac, 6);

    ControlMessage parsed;
    EXPECT(parseControl(message, sizeof(message), &parsed));
    EXPECT(parsed.type == kQueryCmplt);
    EXPECT(parsed.requestID == 7);
    EXPECT(parsed.bufferLength == 6);
    EXPECT(parsed.buffer && memcmp(parsed.buffer, mac, 6) == 0);

    writeLE32(message + 16, 64); // buffer overruns message
    EXPECT(!parseControl(message, sizeof(message), &parsed));
}

static void testParseInitializeComplete() {
    uint8_t message[52] = {};
    writeLE32(message + 0, kInitializeCmplt);
    writeLE32(message + 4, 52);
    writeLE32(message + 8, 1);
    writeLE32(message + 36, 1580);
    ControlMessage parsed;
    EXPECT(parseControl(message, sizeof(message), &parsed));
    EXPECT(parsed.maxTransferSize == 1580);
    EXPECT(!parseControl(message, 8, &parsed));
}

static void testWrapAndIterateMultipleFrames() {
    std::vector<uint8_t> first(60, 0xAB), second(90, 0xCD);
    std::vector<uint8_t> transfer(2 * kPacketHeaderLength + 150 + 8, 0);
    size_t a = wrapPacket(transfer.data(), transfer.size(), first.data(), first.size());
    size_t b = wrapPacket(transfer.data() + a, transfer.size() - a, second.data(), second.size());
    EXPECT(a == 104 && b == 134);
    EXPECT(readLE32(transfer.data() + 8) == 36);

    PacketIterator iterator(transfer.data(), transfer.size());
    const uint8_t *frame = nullptr;
    size_t length = 0;
    EXPECT(iterator.next(&frame, &length) && length == 60 && frame[0] == 0xAB);
    EXPECT(iterator.next(&frame, &length) && length == 90 && frame[0] == 0xCD);
    EXPECT(!iterator.next(&frame, &length));
}

static void testIteratorRejectsTruncatedMessage() {
    std::vector<uint8_t> frame(60, 1), buffer(200, 0);
    size_t n = wrapPacket(buffer.data(), buffer.size(), frame.data(), frame.size());
    PacketIterator iterator(buffer.data(), n - 10);
    const uint8_t *out = nullptr;
    size_t length = 0;
    EXPECT(!iterator.next(&out, &length));
}

static void testFindDataInterface() {
    const uint8_t config[] = {
        9, 2, 75, 0, 2, 1, 0, 0x80, 250,
        8, 0x0B, 0, 2, 0xE0, 0x01, 0x03, 0,
        9, 4, 0, 0, 1, 0xE0, 0x01, 0x03, 0,
        7, 5, 0x81, 3, 8, 0, 9,
        9, 4, 1, 0, 2, 0x0A, 0, 0, 0,
        7, 5, 0x82, 2, 0, 2, 0,
        7, 5, 0x01, 2, 0, 2, 0,
        9, 4, 2, 0, 2, 0xFF, 0x42, 1, 0, // ADB interface after it
        7, 5, 0x83, 2, 0, 2, 0,
        7, 5, 0x02, 2, 0, 2, 0,
    };
    DataInterfaceInfo info;
    EXPECT(findDataInterface(config, sizeof(config), 0, &info));
    EXPECT(info.interfaceNumber == 1);
    EXPECT(info.bulkInAddress == 0x82);
    EXPECT(info.bulkOutAddress == 0x01);
    EXPECT(info.bulkInMaxPacket == 512);
    EXPECT(!findDataInterface(config, sizeof(config), 1, &info));
}

int main() {
    testInitializeEncoding();
    testSetCarriesValueAtOffset20();
    testParseQueryCompleteWithMAC();
    testParseInitializeComplete();
    testWrapAndIterateMultipleFrames();
    testIteratorRejectsTruncatedMessage();
    testFindDataInterface();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("RNDISCodec: all tests passed\n");
    return 0;
}
