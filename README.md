# Android USB Tethering for macOS

A macOS menu-bar app that lets a Mac use an Android phone's **USB tethering** connection.

Most Android phones share their connection over USB using Microsoft **RNDIS**, which macOS does not
support. This project provides two drivers, neither of which needs a kernel extension or reduced
system security:

| Mode | What you get | Requirements |
|---|---|---|
| **User-space driver** (default build) | A `utun` interface with DHCP, SLAAC (IPv6), routes and DNS run by the helper | A free Apple ID is enough |
| **DriverKit network driver** (optional build) | A real Ethernet interface (`enX`) in System Settings → Network. macOS itself handles DHCP, IPv6, DNS, Bonjour and service order. | Paid Apple Developer Program + Apple-approved DriverKit entitlements (see [Driver entitlements](#driver-entitlements)) |

The project has two app targets (schemes):

| Scheme | Contains | Signing |
|---|---|---|
| `AndroidUSBTethering` | App + user-space helper | Free Apple ID ("Personal Team") |
| `AndroidUSBTetheringDriverKit` | App + helper + DriverKit driver | Paid membership; Personal Teams cannot use the System Extension capability |

In the DriverKit build, the driver claims the phone first. If it isn't installed, the helper uses the
user-space driver after a short grace period.

> **Status:** early development (v0.1.0). The protocol logic is unit-tested, but the app has not yet
> been validated end-to-end on many phone models. Please report results in the Issues.

## How it works

### DriverKit mode

`AndroidRNDISDriver` (`Driver/`) is a DriverKit extension built on USBDriverKit and
NetworkingDriverKit. It matches the phone's RNDIS interface, opens the paired CDC Data interface,
performs the RNDIS handshake and registers an `IOUserNetworkEthernet` interface. Frames move between
the networking stack's packet queues and the USB bulk endpoints, wrapped in RNDIS `PACKET_MSG`s.
From then on macOS treats the phone like any USB Ethernet adapter.

### User-space fallback

1. A privileged helper (`launchd` daemon) watches for Android phones with USB tethering turned on.
2. For an RNDIS phone it opens the USB interfaces with **IOUSBHost** and performs the RNDIS
   handshake (INITIALIZE → query MAC → set packet filter).
3. A built-in **DHCP client** gets an IPv4 address, gateway and DNS servers from the phone.
4. The helper creates a **`utun`** interface, configures it, adds routes and publishes DNS.
5. **IPv6**: a built-in **SLAAC client** sends a Router Solicitation, reads the phone's Router
   Advertisement (/64 prefix, RDNSS DNS servers), assigns a privacy address and adds IPv6 routes.
   This only works when the phone's own mobile data or Wi-Fi network provides IPv6.
6. **`PacketBridge`** moves traffic between Ethernet frames on the USB link and IP packets on
   `utun`. It resolves neighbours with ARP for IPv4 and Neighbor Discovery for IPv6.

Phones that use **CDC-NCM** already work with macOS, so the app only reports them.

See [docs/architecture.md](docs/architecture.md) for the design (MVC, class diagram),
[docs/tethering-process.bpmn](docs/tethering-process.bpmn) for the BPMN 2.0 process model, and
[docs/rndis-protocol.md](docs/rndis-protocol.md) for protocol notes.

## Requirements

- macOS 13 Ventura or later (Apple Silicon or Intel)
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple ID added to Xcode (Settings → Accounts). A free account is enough for the default build.
- A paid Apple Developer Program membership only for the DriverKit build or for notarized
  distribution

## Building

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open AndroidUSBTethering.xcodeproj
```

In Xcode:

1. Select the **`AndroidUSBTethering`** scheme (not `AndroidUSBTetheringDriverKit`).
2. For both the `AndroidUSBTethering` and `AndroidUSBTetheringHelper` targets, open *Signing &
   Capabilities* and choose your team ("Your Name (Personal Team)" works). To avoid doing this after
   each `xcodegen generate`, put your Team ID in `DEVELOPMENT_TEAM` in `project.yml`.
3. Build with **Product → Archive**, or build and copy `AndroidUSBTethering.app` to `/Applications`,
   then open it from there.

If the bundle identifier is already taken for your team, change `com.aedkymish` in `project.yml`.

Build and test the core library without Xcode:

```bash
swift build
```

```bash
swift test
```

## Usage

1. Launch the app. A cable icon appears in the menu bar.
2. Click **Install Helper** and approve it in **System Settings → General → Login Items**.
3. DriverKit build only: click **Install Network Driver** and allow it in **System Settings →
   General → Login Items & Extensions → Driver Extensions**. The app must be in `/Applications`.
4. Connect the phone with a USB cable and turn on **Settings → Network & internet → Hotspot &
   tethering → USB tethering** on the phone.
5. The app connects automatically, or click **Connect** in the menu. With the network driver, the
   phone appears in System Settings → Network as an Ethernet service.

Settings:

- **Connect automatically**: start as soon as a tethering phone is plugged in.
- **Route all traffic**: send all IPv4 traffic through the phone. When this is off, only the phone's
  subnet goes through it.
- **Use the phone's DNS**: publish the phone's DNS servers (IPv4 and IPv6) to macOS.
- **Enable IPv6**: configure IPv6 when the phone advertises it.

## Project layout

```
Package.swift               TetheringCore Swift package
Sources/TetheringCore/
  Networking/               MAC/IPv4/IPv6 addresses, Ethernet, IPv4, IPv6, UDP, checksums
  USB/                      Device monitor, descriptor parser, IOUSBHost channel
  RNDIS/                    RNDIS messages, packet codec, RNDISTransport
  Transport/                TetheringTransport protocol
  Interface/                VirtualInterface protocol, UtunInterface
  DHCP/                     DHCP messages and client state machine
  ARP/                      ARP packets and resolver (IPv4)
  NDP/                      Neighbor Discovery messages, resolver and SLAAC client (IPv6)
  Session/                  TetheringSession (state machine), PacketBridge
  System/                   RouteManager, DNSConfigurator, CommandRunner
  XPC/                      App ⇄ helper contract (TetheringHelperProtocol)
Tests/TetheringCoreTests/   Unit tests (mock phone, DHCP, ARP, NDP/SLAAC, bridge, descriptors)
App/                        SwiftUI menu-bar app (Model / View / Controller)
Driver/                     DriverKit extension: AndroidRNDISDriver (.iig/.cpp), portable RNDIS
                            codec + C++ tests, Info.plist/entitlements generator
Helper/                     Privileged launchd daemon + plist
docs/                       Architecture, BPMN 2.0 model, protocol notes
project.yml                 XcodeGen spec for the app and helper targets
```

## Driver entitlements

A DriverKit extension only loads when it is signed with entitlements Apple grants on request at
<https://developer.apple.com/contact/request/system-extension/>:

| Entitlement | Purpose |
|---|---|
| `com.apple.developer.driverkit` | Run as a DriverKit extension |
| `com.apple.developer.driverkit.family.networking` | Register a network interface |
| `com.apple.developer.driverkit.transport.usb` | Access USB devices from the listed vendor IDs |
| `com.apple.developer.system-extension.install` (app) | Let the app activate the extension |

The vendor IDs (Google, Samsung, Xiaomi, OnePlus, Motorola and others) are listed once in
`Driver/Scripts/generate_driver_plists.py`. That script writes both `Driver/Info.plist` (IOKit
personalities) and `Driver/AndroidRNDISDriver.entitlements`. To add a vendor, edit `VENDORS` and run:

```bash
python3 Driver/Scripts/generate_driver_plists.py
```

For local development before the entitlements are approved, you can turn on developer mode for
system extensions. This requires System Integrity Protection to be disabled on that test Mac:

```bash
systemextensionsctl developer on
```

Check the driver's state and logs:

```bash
systemextensionsctl list
```

```bash
log stream --predicate 'sender == "com.aedkymish.AndroidUSBTethering.RNDISDriver"'
```

## Known limitations

- IPv6 depends on the phone: Android only advertises IPv6 to tethered devices when its upstream
  network has IPv6. DHCPv6 is not used (Android tethering does not offer it).
- Duplicate Address Detection is skipped for the SLAAC address. The address uses a random 64-bit
  interface identifier, so collisions are extremely unlikely.
- The DriverKit driver has been compiled against the macOS SDK but not yet tested on real phones.
  Please report results.
- In user-space mode the link is a layer-3 `utun` interface, so it does not appear as an Ethernet
  service in System Settings. Use the DriverKit driver for that.
- Turning on tethering still has to be done on the phone.

## Troubleshooting

View the helper's logs:

```bash
log stream --predicate 'subsystem == "com.aedkymish.AndroidUSBTethering.helper"'
```

Check the interface and routes while connected:

```bash
ifconfig | grep -A4 utun
```

```bash
netstat -rn -f inet | head -20
```

```bash
netstat -rn -f inet6 | head -20
```
