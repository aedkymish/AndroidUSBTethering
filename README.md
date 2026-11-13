# Android USB Tethering for macOS

A macOS menu-bar app that lets a Mac use an Android phone's **USB tethering** connection.

Most Android phones share their connection over USB using Microsoft **RNDIS**, which macOS does not
support. This project adds a user-space RNDIS driver and IPv4 network bridge, so no kernel extension
and no reduced system security are needed.

> **Status:** early development (v0.1.0). The protocol logic is unit-tested, but the app has not yet
> been validated end-to-end on many phone models. Please report results in the Issues.

## How it works

1. A privileged helper (`launchd` daemon) watches for Android phones with USB tethering turned on.
2. For an RNDIS phone it opens the USB interfaces with **IOUSBHost** and performs the RNDIS
   handshake (INITIALIZE → query MAC → set packet filter).
3. A built-in **DHCP client** gets an IP address, gateway and DNS servers from the phone.
4. The helper creates a **`utun`** interface, configures it, adds routes and publishes DNS.
5. **`PacketBridge`** moves traffic between Ethernet frames on the USB link and IP packets on
   `utun`, including ARP.

Phones that use **CDC-NCM** already work with macOS, so the app only reports them.

See [docs/architecture.md](docs/architecture.md) for the design (MVC, class diagram),
[docs/tethering-process.bpmn](docs/tethering-process.bpmn) for the BPMN 2.0 process model, and
[docs/rndis-protocol.md](docs/rndis-protocol.md) for protocol notes.

## Requirements

- macOS 13 Ventura or later (Apple Silicon or Intel)
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple Developer ID to sign and notarize the app for distribution

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

Set your team in `project.yml` (`DEVELOPMENT_TEAM`) or in Xcode's *Signing & Capabilities*, then build
and run the `AndroidUSBTethering` scheme.

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
3. Connect the phone with a USB cable and turn on **Settings → Network & internet → Hotspot &
   tethering → USB tethering** on the phone.
4. The app connects automatically, or click **Connect** in the menu.

Settings:

- **Connect automatically**: start as soon as a tethering phone is plugged in.
- **Route all traffic**: send all IPv4 traffic through the phone. When this is off, only the phone's
  subnet goes through it.
- **Use the phone's DNS**: publish the phone's DNS servers to macOS.

## Project layout

```
Package.swift               TetheringCore Swift package
Sources/TetheringCore/
  Networking/               MAC/IPv4 addresses, Ethernet, IPv4, UDP, checksums
  USB/                      Device monitor, descriptor parser, IOUSBHost channel
  RNDIS/                    RNDIS messages, packet codec, RNDISTransport
  Transport/                TetheringTransport protocol
  Interface/                VirtualInterface protocol, UtunInterface
  DHCP/                     DHCP messages and client state machine
  ARP/                      ARP packets and resolver
  Session/                  TetheringSession (state machine), PacketBridge
  System/                   RouteManager, DNSConfigurator, CommandRunner
  XPC/                      App ⇄ helper contract (TetheringHelperProtocol)
Tests/TetheringCoreTests/   Unit tests (mock phone, DHCP/ARP/bridge, descriptors)
App/                        SwiftUI menu-bar app (Model / View / Controller)
Helper/                     Privileged launchd daemon + plist
docs/                       Architecture, BPMN 2.0 model, protocol notes
project.yml                 XcodeGen spec for the app and helper targets
```

## Known limitations

- IPv4 only; IPv6 is not bridged yet.
- `utun` is a layer-3 interface, so the link does not appear as an Ethernet service in System
  Settings. A DriverKit (`IOUserNetworkEthernet`) backend is on the roadmap.
- Turning on tethering still has to be done on the phone.

## Troubleshooting

View the helper's logs:

```bash
log stream --predicate 'subsystem == "com.aedkymish.AndroidUSBTethering.helper"'
```

Check the interface and routes while connected:

```bash
ifconfig | grep -A3 utun
```

```bash
netstat -rn -f inet | head -20
```
