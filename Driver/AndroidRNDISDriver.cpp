//
//  AndroidRNDISDriver.cpp
//  AndroidRNDISDriver
//
//  Matches the RNDIS communication interface of an Android phone, opens the paired CDC Data
//  interface, performs the RNDIS handshake and registers an Ethernet interface with the
//  networking stack. macOS then runs DHCP, IPv6 SLAAC, ARP/NDP and DNS on it natively.
//
//  Data path:
//    TX: stack -> TxSubmissionQueue -> wrap PACKET_MSG -> bulk OUT -> TxCompletionQueue
//    RX: bulk IN -> unwrap PACKET_MSGs -> RxSubmissionQueue packet -> RxCompletionQueue -> stack
//

#include <os/log.h>
#include <string.h>

#include <DriverKit/DriverKit.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODataQueueDispatchSource.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/OSAction.h>
#include <NetworkingDriverKit/NetworkingDriverKit.h>
#include <USBDriverKit/USBDriverKit.h>

#include "AndroidRNDISDriver.h"
#include "RNDISCodec.hpp"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "AndroidRNDISDriver: " fmt, ##__VA_ARGS__)

namespace {
constexpr uint32_t kControlTimeoutMs = 5000;
constexpr uint32_t kBulkOutTimeoutMs = 2000;
constexpr uint32_t kResponsePollAttempts = 500;
constexpr uint32_t kResponsePollIntervalMs = 10;
constexpr uint32_t kPoolPacketCount = 256;
constexpr uint32_t kPoolBufferSize = 2048;
constexpr uint32_t kQueueCapacity = 64;
constexpr uint32_t kTxBatch = 16;
constexpr uint32_t kMTU = 1500;
} // namespace

struct AndroidRNDISDriver_IVars {
    IOUSBHostInterface *controlInterface;
    IOUSBHostInterface *dataInterface;
    IOUSBHostPipe *bulkIn;
    IOUSBHostPipe *bulkOut;
    uint8_t controlInterfaceNumber;

    IOBufferMemoryDescriptor *controlBuffer;
    IOBufferMemoryDescriptor *rxBuffer;
    IOBufferMemoryDescriptor *txBuffer;
    uint32_t maxTransferSize;
    uint32_t nextRequestID;
    uint8_t macAddress[6];

    IODispatchQueue *txDispatchQueue;
    IODispatchQueue *rxDispatchQueue;
    IOUserNetworkPacketBufferPool *pool;
    IOUserNetworkTxSubmissionQueue *txSubmission;
    IOUserNetworkTxCompletionQueue *txCompletion;
    IOUserNetworkRxSubmissionQueue *rxSubmission;
    IOUserNetworkRxCompletionQueue *rxCompletion;
    OSAction *txAction;
    OSAction *bulkInAction;

    bool started;
    bool enabled;
};

// MARK: - Helpers (USB / RNDIS control plane)

static uint8_t *bufferAddress(IOBufferMemoryDescriptor *buffer) {
    IOAddressSegment segment = {};
    buffer->GetAddressRange(&segment);
    return reinterpret_cast<uint8_t *>(segment.address);
}

static kern_return_t sendControl(AndroidRNDISDriver_IVars *ivars, const uint8_t *message, size_t length) {
    memcpy(bufferAddress(ivars->controlBuffer), message, length);
    ivars->controlBuffer->SetLength(length);
    uint16_t transferred = 0;
    return ivars->controlInterface->DeviceRequest(rndis::kRequestTypeOut, rndis::kSendEncapsulatedCommand,
                                                  0, ivars->controlInterfaceNumber, (uint16_t)length,
                                                  ivars->controlBuffer, &transferred, kControlTimeoutMs);
}

/// Sends a request and polls GET_ENCAPSULATED_RESPONSE until the completion with the same
/// request ID arrives, answering KEEPALIVE messages in between. The response bytes stay in
/// ivars->controlBuffer and `out->buffer` points into it.
static kern_return_t request(AndroidRNDISDriver_IVars *ivars, const uint8_t *message, size_t length,
                             uint32_t expectedType, rndis::ControlMessage *out) {
    const uint32_t requestID = rndis::readLE32(message + 8);
    kern_return_t ret = sendControl(ivars, message, length);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    for (uint32_t attempt = 0; attempt < kResponsePollAttempts; attempt++) {
        ivars->controlBuffer->SetLength(rndis::kControlBufferSize);
        uint16_t transferred = 0;
        ret = ivars->controlInterface->DeviceRequest(rndis::kRequestTypeIn, rndis::kGetEncapsulatedResponse,
                                                     0, ivars->controlInterfaceNumber,
                                                     (uint16_t)rndis::kControlBufferSize,
                                                     ivars->controlBuffer, &transferred, kControlTimeoutMs);
        if (ret == kIOReturnSuccess && transferred >= 12 &&
            rndis::parseControl(bufferAddress(ivars->controlBuffer), transferred, out)) {
            if (out->type == rndis::kKeepAliveMsg) {
                uint8_t reply[16];
                size_t n = rndis::buildKeepAliveComplete(reply, sizeof(reply), out->requestID);
                sendControl(ivars, reply, n);
                continue;
            }
            if (out->type == expectedType && out->requestID == requestID) {
                return out->status == rndis::kStatusSuccess ? kIOReturnSuccess : kIOReturnError;
            }
            continue;
        }
        IOSleep(kResponsePollIntervalMs);
    }
    return kIOReturnTimeout;
}

static kern_return_t performHandshake(AndroidRNDISDriver_IVars *ivars) {
    uint8_t message[64];
    rndis::ControlMessage response;

    size_t n = rndis::buildInitialize(message, sizeof(message), ivars->nextRequestID++,
                                      rndis::kRequestedMaxTransfer);
    kern_return_t ret = request(ivars, message, n, rndis::kInitializeCmplt, &response);
    if (ret != kIOReturnSuccess) {
        Log("INITIALIZE failed: 0x%x", ret);
        return ret;
    }
    ivars->maxTransferSize = rndis::kRequestedMaxTransfer;
    if (response.maxTransferSize > 0 && response.maxTransferSize < ivars->maxTransferSize) {
        ivars->maxTransferSize = response.maxTransferSize;
    }

    n = rndis::buildQuery(message, sizeof(message), ivars->nextRequestID++, rndis::kOid8023PermanentAddress);
    ret = request(ivars, message, n, rndis::kQueryCmplt, &response);
    if (ret != kIOReturnSuccess || response.bufferLength < 6) {
        Log("QUERY MAC failed: 0x%x", ret);
        return ret != kIOReturnSuccess ? ret : kIOReturnUnderrun;
    }
    memcpy(ivars->macAddress, response.buffer, 6);

    uint8_t filter[4];
    rndis::writeLE32(filter, rndis::kPacketFilterStandard);
    n = rndis::buildSet(message, sizeof(message), ivars->nextRequestID++, rndis::kOidGenCurrentPacketFilter,
                        filter, sizeof(filter));
    ret = request(ivars, message, n, rndis::kSetCmplt, &response);
    if (ret != kIOReturnSuccess) {
        Log("SET packet filter failed: 0x%x", ret);
    }
    return ret;
}

/// Finds the CDC Data interface paired with the matched control interface.
static kern_return_t openDataInterface(IOService *client, AndroidRNDISDriver_IVars *ivars) {
    const IOUSBConfigurationDescriptor *configuration = ivars->controlInterface->CopyConfigurationDescriptor();
    if (configuration == nullptr) {
        return kIOReturnNotFound;
    }
    const IOUSBInterfaceDescriptor *controlDescriptor =
        ivars->controlInterface->GetInterfaceDescriptor(configuration);
    const uint16_t totalLength = rndis::readLE16(reinterpret_cast<const uint8_t *>(configuration) + 2);
    rndis::DataInterfaceInfo info = {};
    bool found = false;
    if (controlDescriptor != nullptr) {
        ivars->controlInterfaceNumber = controlDescriptor->bInterfaceNumber;
        found = rndis::findDataInterface(reinterpret_cast<const uint8_t *>(configuration), totalLength,
                                         ivars->controlInterfaceNumber, &info);
    }
    IOFree(const_cast<IOUSBConfigurationDescriptor *>(configuration), totalLength);
    if (!found) {
        Log("no CDC Data interface with bulk endpoints");
        return kIOReturnNotFound;
    }

    IOUSBHostDevice *device = nullptr;
    kern_return_t ret = ivars->controlInterface->CopyDevice(&device);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    uintptr_t iterator = 0;
    ret = device->CreateInterfaceIterator(&iterator);
    if (ret == kIOReturnSuccess) {
        IOUSBHostInterface *candidate = nullptr;
        while (ivars->dataInterface == nullptr &&
               device->CopyInterface(iterator, &candidate) == kIOReturnSuccess && candidate != nullptr) {
            const IOUSBConfigurationDescriptor *config = candidate->CopyConfigurationDescriptor();
            if (config != nullptr) {
                const IOUSBInterfaceDescriptor *descriptor = candidate->GetInterfaceDescriptor(config);
                if (descriptor != nullptr && descriptor->bInterfaceNumber == info.interfaceNumber) {
                    ivars->dataInterface = candidate;
                    candidate = nullptr;
                }
                IOFree(const_cast<IOUSBConfigurationDescriptor *>(config),
                       rndis::readLE16(reinterpret_cast<const uint8_t *>(config) + 2));
            }
            OSSafeReleaseNULL(candidate);
        }
        device->DestroyInterfaceIterator(iterator);
    }
    OSSafeReleaseNULL(device);
    if (ivars->dataInterface == nullptr) {
        return kIOReturnNotFound;
    }

    ret = ivars->dataInterface->Open(client, 0, nullptr);
    if (ret != kIOReturnSuccess) {
        Log("opening data interface failed: 0x%x", ret);
        OSSafeReleaseNULL(ivars->dataInterface);
        return ret;
    }
    ret = ivars->dataInterface->CopyPipe(info.bulkInAddress, &ivars->bulkIn);
    if (ret == kIOReturnSuccess) {
        ret = ivars->dataInterface->CopyPipe(info.bulkOutAddress, &ivars->bulkOut);
    }
    return ret;
}

// MARK: - Lifecycle

bool AndroidRNDISDriver::init() {
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(AndroidRNDISDriver_IVars, 1);
    if (ivars == nullptr) {
        return false;
    }
    ivars->nextRequestID = 1;
    return true;
}

void AndroidRNDISDriver::free() {
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->txAction);
        OSSafeReleaseNULL(ivars->bulkInAction);
        OSSafeReleaseNULL(ivars->txSubmission);
        OSSafeReleaseNULL(ivars->txCompletion);
        OSSafeReleaseNULL(ivars->rxSubmission);
        OSSafeReleaseNULL(ivars->rxCompletion);
        OSSafeReleaseNULL(ivars->pool);
        OSSafeReleaseNULL(ivars->txDispatchQueue);
        OSSafeReleaseNULL(ivars->rxDispatchQueue);
        OSSafeReleaseNULL(ivars->controlBuffer);
        OSSafeReleaseNULL(ivars->rxBuffer);
        OSSafeReleaseNULL(ivars->txBuffer);
        OSSafeReleaseNULL(ivars->bulkIn);
        OSSafeReleaseNULL(ivars->bulkOut);
        OSSafeReleaseNULL(ivars->dataInterface);
        OSSafeReleaseNULL(ivars->controlInterface);
    }
    IOSafeDeleteNULL(ivars, AndroidRNDISDriver_IVars, 1);
    super::free();
}

kern_return_t IMPL(AndroidRNDISDriver, Start) {
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    ivars->controlInterface = OSDynamicCast(IOUSBHostInterface, provider);
    if (ivars->controlInterface == nullptr) {
        return kIOReturnBadArgument;
    }
    ivars->controlInterface->retain();

    ret = ivars->controlInterface->Open(this, 0, nullptr);
    if (ret != kIOReturnSuccess) {
        Log("opening control interface failed: 0x%x", ret);
        goto fail;
    }
    ret = openDataInterface(this, ivars);
    if (ret != kIOReturnSuccess) {
        goto fail;
    }

    ret = ivars->controlInterface->CreateIOBuffer(kIOMemoryDirectionInOut, rndis::kControlBufferSize,
                                                  &ivars->controlBuffer);
    if (ret == kIOReturnSuccess) {
        ret = performHandshake(ivars);
    }
    if (ret == kIOReturnSuccess) {
        ret = ivars->dataInterface->CreateIOBuffer(kIOMemoryDirectionIn, ivars->maxTransferSize, &ivars->rxBuffer);
    }
    if (ret == kIOReturnSuccess) {
        ret = ivars->dataInterface->CreateIOBuffer(kIOMemoryDirectionOut,
                                                   rndis::kPacketHeaderLength + kPoolBufferSize, &ivars->txBuffer);
    }
    if (ret != kIOReturnSuccess) {
        goto fail;
    }

    // Packet pool and the four queues shared with the networking stack.
    ret = IODispatchQueue::Create("TxDispatchQueue", 0, 0, &ivars->txDispatchQueue);
    if (ret == kIOReturnSuccess) {
        ret = SetDispatchQueue("TxDispatchQueue", ivars->txDispatchQueue);
    }
    if (ret == kIOReturnSuccess) {
        ret = IODispatchQueue::Create("RxDispatchQueue", 0, 0, &ivars->rxDispatchQueue);
    }
    if (ret == kIOReturnSuccess) {
        ret = SetDispatchQueue("RxDispatchQueue", ivars->rxDispatchQueue);
    }
    if (ret == kIOReturnSuccess) {
        ret = IOUserNetworkPacketBufferPool::Create(this, "AndroidRNDISPool", kPoolPacketCount, kPoolPacketCount,
                                                    kPoolBufferSize, &ivars->pool);
    }
    if (ret == kIOReturnSuccess) {
        ret = IOUserNetworkTxSubmissionQueue::Create(ivars->pool, this, kQueueCapacity, 0,
                                                     ivars->txDispatchQueue, &ivars->txSubmission);
    }
    if (ret == kIOReturnSuccess) {
        ret = IOUserNetworkTxCompletionQueue::Create(ivars->pool, this, kQueueCapacity, 0,
                                                     ivars->txDispatchQueue, &ivars->txCompletion);
    }
    if (ret == kIOReturnSuccess) {
        ret = IOUserNetworkRxSubmissionQueue::Create(ivars->pool, this, kQueueCapacity, 0,
                                                     ivars->rxDispatchQueue, &ivars->rxSubmission);
    }
    if (ret == kIOReturnSuccess) {
        ret = IOUserNetworkRxCompletionQueue::Create(ivars->pool, this, kQueueCapacity, 0,
                                                     ivars->rxDispatchQueue, &ivars->rxCompletion);
    }
    if (ret != kIOReturnSuccess) {
        Log("creating packet queues failed: 0x%x", ret);
        goto fail;
    }

    // Outbound notifications from the Tx submission queue.
    ret = CreateActionTxPacketsAvailable(0, &ivars->txAction);
    if (ret == kIOReturnSuccess) {
        IODataQueueDispatchSource *source = nullptr;
        ret = ivars->txSubmission->CopyDataQueue(&source);
        if (ret == kIOReturnSuccess) {
            ret = source->SetDataAvailableHandler(ivars->txAction);
        }
        OSSafeReleaseNULL(source);
    }
    if (ret == kIOReturnSuccess) {
        ret = CreateActionBulkInComplete(0, &ivars->bulkInAction);
    }
    if (ret != kIOReturnSuccess) {
        goto fail;
    }

    {
        IOUserNetworkPacketQueue *queues[] = {ivars->txSubmission, ivars->txCompletion,
                                              ivars->rxSubmission, ivars->rxCompletion};
        IOUserNetworkMACAddress mac = {};
        memcpy(mac.octet, ivars->macAddress, sizeof(mac.octet));
        ret = RegisterEthernetInterface(mac, ivars->pool, queues, 4);
        if (ret != kIOReturnSuccess) {
            Log("RegisterEthernetInterface failed: 0x%x", ret);
            goto fail;
        }
    }

    {
        const IOUserNetworkMediaType media[] = {kIOUserNetworkMediaEthernetAuto};
        ReportAvailableMediaTypes(media, 1);
        ReportLinkStatus(kIOUserNetworkLinkStatusActive, kIOUserNetworkMediaEthernetAuto);
    }

    ret = ivars->bulkIn->AsyncIO(ivars->rxBuffer, ivars->maxTransferSize, ivars->bulkInAction, 0);
    if (ret != kIOReturnSuccess) {
        Log("starting bulk IN failed: 0x%x", ret);
        goto fail;
    }

    ivars->started = true;
    Log("started, MAC %02x:%02x:%02x:%02x:%02x:%02x", ivars->macAddress[0], ivars->macAddress[1],
        ivars->macAddress[2], ivars->macAddress[3], ivars->macAddress[4], ivars->macAddress[5]);
    RegisterService();
    return kIOReturnSuccess;

fail:
    // Release the USB interfaces so the user-space fallback in the helper can use the phone.
    if (ivars->dataInterface != nullptr) {
        ivars->dataInterface->Close(this, 0);
    }
    ivars->controlInterface->Close(this, 0);
    return ret != kIOReturnSuccess ? ret : kIOReturnError;
}

kern_return_t IMPL(AndroidRNDISDriver, Stop) {
    if (ivars->started) {
        ReportLinkStatus(kIOUserNetworkLinkStatusInactive, kIOUserNetworkMediaEthernetAuto);
        uint8_t halt[16];
        size_t n = rndis::buildHalt(halt, sizeof(halt), ivars->nextRequestID++);
        sendControl(ivars, halt, n);
        ivars->started = false;
    }
    if (ivars->bulkIn != nullptr) {
        ivars->bulkIn->Abort(0, kIOReturnAborted, this);
    }
    if (ivars->bulkOut != nullptr) {
        ivars->bulkOut->Abort(0, kIOReturnAborted, this);
    }
    if (ivars->txAction != nullptr) {
        ivars->txAction->Cancel(nullptr);
    }
    if (ivars->bulkInAction != nullptr) {
        ivars->bulkInAction->Cancel(nullptr);
    }
    if (ivars->dataInterface != nullptr) {
        ivars->dataInterface->Close(this, 0);
    }
    if (ivars->controlInterface != nullptr) {
        ivars->controlInterface->Close(this, 0);
    }
    return Stop(provider, SUPERDISPATCH);
}

// MARK: - Data plane

void IMPL(AndroidRNDISDriver, TxPacketsAvailable) {
    IOUserNetworkPacket *packets[kTxBatch];
    uint8_t *usbBuffer = bufferAddress(ivars->txBuffer);
    const size_t usbCapacity = rndis::kPacketHeaderLength + kPoolBufferSize;

    uint32_t count;
    while ((count = ivars->txSubmission->DequeuePackets(packets, kTxBatch)) > 0) {
        for (uint32_t i = 0; i < count; i++) {
            IOUserNetworkPacket *packet = packets[i];
            if (!ivars->enabled || ivars->bulkOut == nullptr) {
                continue;
            }
            const uint8_t *frame = reinterpret_cast<const uint8_t *>(packet->getDataVirtualAddress()) +
                                   packet->getDataOffset();
            const uint32_t frameLength = packet->getDataLength();
            const size_t length = rndis::wrapPacket(usbBuffer, usbCapacity, frame, frameLength);
            if (length == 0) {
                continue;
            }
            uint32_t transferred = 0;
            ivars->txBuffer->SetLength(length);
            ivars->bulkOut->IO(ivars->txBuffer, (uint32_t)length, &transferred, kBulkOutTimeoutMs);
        }
        ivars->txCompletion->EnqueuePackets(packets, count);
    }
}

void IMPL(AndroidRNDISDriver, BulkInComplete) {
    if (status == kIOReturnAborted || !ivars->started) {
        return;
    }
    if (status == kIOReturnSuccess && ivars->enabled) {
        rndis::PacketIterator iterator(bufferAddress(ivars->rxBuffer), actualByteCount);
        const uint8_t *frame = nullptr;
        size_t frameLength = 0;
        while (iterator.next(&frame, &frameLength)) {
            if (frameLength > kPoolBufferSize) {
                continue;
            }
            IOUserNetworkPacket *packet = nullptr;
            if (ivars->rxSubmission->DequeuePacket(&packet) != kIOReturnSuccess || packet == nullptr) {
                break; // stack has no free buffers; drop the rest of this transfer
            }
            memcpy(reinterpret_cast<uint8_t *>(packet->getDataVirtualAddress()), frame, frameLength);
            packet->setDataOffsetAndLength(0, (uint32_t)frameLength);
            packet->setLinkHeaderLength(14);
            ivars->rxCompletion->EnqueuePacket(packet);
        }
    } else if (status != kIOReturnSuccess) {
        Log("bulk IN error 0x%x", status);
        ivars->bulkIn->ClearStall(true); // recovers from a stalled endpoint; harmless otherwise
    }
    ivars->bulkIn->AsyncIO(ivars->rxBuffer, ivars->maxTransferSize, ivars->bulkInAction, 0);
}

// MARK: - Controller interface

kern_return_t IMPL(AndroidRNDISDriver, SetInterfaceEnable) {
    ivars->enabled = isEnable;
    ReportLinkStatus(isEnable ? kIOUserNetworkLinkStatusActive : kIOUserNetworkLinkStatusInactive,
                     kIOUserNetworkMediaEthernetAuto);
    return kIOReturnSuccess;
}

kern_return_t IMPL(AndroidRNDISDriver, SetPromiscuousModeEnable) {
    return kIOReturnSuccess; // the phone's filter is fixed; promiscuous mode is not meaningful
}

kern_return_t IMPL(AndroidRNDISDriver, SetMulticastAddresses) {
    return kIOReturnSuccess; // ALL_MULTICAST is always enabled in the RNDIS packet filter
}

kern_return_t IMPL(AndroidRNDISDriver, SetAllMulticastModeEnable) {
    return kIOReturnSuccess;
}

kern_return_t IMPL(AndroidRNDISDriver, SelectMediaType) {
    return kIOReturnSuccess;
}

kern_return_t IMPL(AndroidRNDISDriver, SetWakeOnMagicPacketEnable) {
    return kIOReturnUnsupported;
}

kern_return_t IMPL(AndroidRNDISDriver, SetMTU) {
    return mtu <= kMTU ? kIOReturnSuccess : kIOReturnUnsupported;
}

kern_return_t IMPL(AndroidRNDISDriver, GetMaxTransferUnit) {
    *mtu = kMTU;
    return kIOReturnSuccess;
}

kern_return_t IMPL(AndroidRNDISDriver, SetHardwareAssists) {
    return kIOReturnSuccess;
}

kern_return_t IMPL(AndroidRNDISDriver, GetHardwareAssists) {
    *hardwareAssists = 0;
    return kIOReturnSuccess;
}
