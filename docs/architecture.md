# Architecture

Android USB Tethering is split into three deployable parts that follow **MVC** on the UI side and
**object-oriented, protocol-based design** in the core.

```
┌─────────────── AndroidUSBTethering.app (user) ───────────────┐
│  Model       AppModel (ObservableObject), HelperInstallState │
│  View        MenuBarView, SettingsView, MenuBarLabel         │
│  Controller  TetheringController, HelperConnection,          │
│              HelperInstaller (SMAppService)                  │
└──────────────────────────────┬───────────────────────────────┘
                               │ NSXPCConnection (.privileged)
                               │ TetheringHelperProtocol, JSON payloads
┌──────────────────────────────▼───────────────────────────────┐
│  AndroidUSBTetheringHelper (launchd daemon, root)            │
│  HelperService ── USBDeviceMonitor ── TetheringSession       │
└──────────────────────────────┬───────────────────────────────┘
                               │ links
┌──────────────────────────────▼───────────────────────────────┐
│  TetheringCore (Swift package, unit-tested)                  │
└──────────────────────────────────────────────────────────────┘
```

## Why a privileged helper?

Opening the phone's USB interfaces, creating a `utun` interface, changing routes and publishing DNS
all require root. The app stays unprivileged; the helper is registered with
`SMAppService.daemon(plistName:)` and only accepts XPC connections from the signed app
(`setCodeSigningRequirement` in release builds).

## Data path

```
 macOS apps ──IP──► utunN ──► UtunInterface ──► PacketBridge ──► ARPResolver ──Ethernet──►
     RNDISTransport ──PACKET_MSG──► IOUSBHostChannel ──bulk OUT──► phone
 phone ──bulk IN──► IOUSBHostChannel ──► RNDISTransport ──Ethernet──► TetheringSession
     ├─ DHCP reply?  ──► DHCPClient
     └─ otherwise    ──► PacketBridge ──IP──► UtunInterface ──► macOS
```

`utun` is a layer-3 interface while RNDIS is layer 2, so `PacketBridge` adds and strips Ethernet
headers, answers ARP for the host address and resolves the phone's MAC address. DHCP runs in user
space before the interface is configured.

## Class diagram

```mermaid
classDiagram
    direction LR

    class TetheringTransport {
        <<protocol>>
        +macAddress: MACAddress
        +onFrameReceived: (Data) -> Void
        +onDisconnect: (Error?) -> Void
        +open()
        +send(frame: Data)
        +close()
    }
    class RNDISUSBChannel {
        <<protocol>>
        +sendEncapsulatedCommand(Data)
        +getEncapsulatedResponse(maxLength) Data
        +writeBulk(Data)
        +startBulkReading(transferSize, handler)
        +close()
    }
    class VirtualInterface {
        <<protocol>>
        +name: String
        +onPacket: (Data) -> Void
        +open()
        +configure(with: DHCPLease)
        +write(ipPacket: Data)
        +close()
    }
    class CommandRunning {
        <<protocol>>
        +run(executable, arguments, input) String
    }

    class RNDISTransport
    class IOUSBHostChannel
    class UtunInterface
    class ProcessCommandRunner
    class RNDISMessage {
        <<enum>>
    }
    class RNDISPacketCodec {
        <<enum>>
    }
    class TetheringSession {
        +state: TetheringState
        +start()
        +stop()
    }
    class TetheringState {
        <<enum>>
    }
    class PacketBridge
    class ARPResolver
    class DHCPClient
    class DHCPMessage
    class RouteManager
    class DNSConfigurator
    class USBDeviceMonitor
    class AndroidDevice
    class HelperService
    class TetheringController
    class AppModel
    class MenuBarView

    TetheringTransport <|.. RNDISTransport
    RNDISUSBChannel <|.. IOUSBHostChannel
    VirtualInterface <|.. UtunInterface
    CommandRunning <|.. ProcessCommandRunner

    RNDISTransport o-- RNDISUSBChannel
    RNDISTransport ..> RNDISMessage
    RNDISTransport ..> RNDISPacketCodec

    TetheringSession o-- TetheringTransport
    TetheringSession o-- VirtualInterface
    TetheringSession *-- DHCPClient
    TetheringSession *-- PacketBridge
    TetheringSession o-- RouteManager
    TetheringSession o-- DNSConfigurator
    TetheringSession --> TetheringState
    PacketBridge *-- ARPResolver
    DHCPClient ..> DHCPMessage
    RouteManager o-- CommandRunning
    DNSConfigurator o-- CommandRunning
    UtunInterface o-- CommandRunning

    HelperService *-- USBDeviceMonitor
    HelperService o-- TetheringSession
    USBDeviceMonitor --> AndroidDevice

    TetheringController *-- AppModel
    MenuBarView ..> AppModel : observes
    MenuBarView ..> TetheringController : user intents
    TetheringController ..> HelperService : XPC
```

## Design decisions

| Decision | Rationale |
|---|---|
| `TetheringTransport` / `RNDISUSBChannel` protocols | The RNDIS logic is tested with a mock phone. The IOUSBHost backend can later be replaced by a DriverKit extension without touching the session. |
| `VirtualInterface` protocol | `UtunInterface` is the MVP. A DriverKit `IOUserNetworkEthernet` interface (real `enX`) can replace it. |
| `CommandRunning` for `ifconfig` / `route` / `scutil` | Keeps system side effects injectable and testable. |
| Split default routes (`0/1`, `128/1`) | Overrides Wi-Fi without deleting the system default route, so cleanup cannot strand the Mac offline. |
| JSON over XPC | One `@objc` protocol with `Data` payloads. Adding fields to `HelperStatus` does not change the XPC interface. |
| One serial queue per component | The session, helper and DHCP client each serialize their state on a single `DispatchQueue`. |

## Process model

The session lifecycle is modelled in BPMN 2.0 in [`tethering-process.bpmn`](tethering-process.bpmn)
(open it in Camunda Modeler or bpmn.io). `TetheringSession`'s states map to its tasks:

| BPMN element | Code |
|---|---|
| Identify interface class | `USBDeviceMonitor.makeDevice(from:)` |
| Gateway "Tethering protocol?" | `HelperService.deviceAttached(_:)` |
| RNDIS INITIALIZE / Query MAC, set packet filter | `RNDISTransport.open()` → `.initializingLink` |
| DHCP discover / request | `DHCPClient` → `.negotiatingDHCP` |
| Create and configure utun, install routes and DNS | `TetheringSession.configureNetwork(with:)` → `.configuringNetwork` |
| Connected (catch event) | `.connected(ConnectionInfo)` |
| Link failure boundary event, roll back | `TetheringSession.teardown(finalState: .failed)` |
| Release DHCP, remove routes and DNS, close | `TetheringSession.teardown(finalState: .idle)` |

## Roadmap

1. **DriverKit**: replace `IOUSBHostChannel` + `UtunInterface` with a DEXT built on USBDriverKit and
   NetworkingDriverKit. This needs Apple's `com.apple.developer.driverkit.family.networking`
   entitlement and gives a real Ethernet interface (IPv6, Bonjour, Network Settings integration).
2. IPv6 bridging (SLAAC / NDP proxying) in `PacketBridge`.
3. Optional `adb` integration to switch on tethering from the Mac.
4. Interrupt-endpoint notifications instead of polling `GET_ENCAPSULATED_RESPONSE`.
