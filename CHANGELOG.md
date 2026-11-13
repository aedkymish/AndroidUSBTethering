# Changelog

All notable changes to this project are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-11-13

First public build.

### Added
- Menu-bar app with a privileged helper that turns an Android phone's USB tethering into a working
  network connection on macOS 13 or later.
- User-space RNDIS driver (IOUSBHost) with DHCP, ARP and a `utun` interface; routes and DNS are
  configured automatically.
- IPv6: SLAAC, Neighbor Discovery and RDNSS (IPv6 DNS servers) when the phone's network provides IPv6.
- Native support reporting for phones using CDC-NCM, which macOS drives without a driver.
- Turn tethering on and off from the Mac through ADB (NCM first, RNDIS fallback).
- Optional DriverKit network driver for a real Ethernet interface (separate
  `AndroidUSBTetheringDriverKit` build; not included in the downloads because it needs Apple-granted
  entitlements).
- About window, app icon and settings for routing, DNS, IPv6 and auto-connect.
- Manual helper installer (`install-helper.sh`) for builds that cannot use SMAppService.
- Apache License 2.0.
