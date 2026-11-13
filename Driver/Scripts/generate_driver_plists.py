#!/usr/bin/env python3
"""Generates Driver/Info.plist and Driver/AndroidRNDISDriver.entitlements from VENDORS.

The USB transport entitlement Apple grants lists vendor IDs, and every IOKit personality must
fall inside it, so both files are generated from the same list. Run after editing VENDORS:

    python3 Driver/Scripts/generate_driver_plists.py
"""
import plistlib
from pathlib import Path

# USB vendor IDs of common Android phone makers.
VENDORS = {
    "Google": 0x18D1,
    "Samsung": 0x04E8,
    "Xiaomi": 0x2717,
    "OnePlus": 0x2A70,
    "Motorola": 0x22B8,
    "Huawei": 0x12D1,
    "Sony": 0x0FCE,
    "LG": 0x1004,
    "OPPO / realme": 0x22D9,
    "vivo": 0x2D95,
    "ZTE": 0x19D2,
    "Lenovo": 0x17EF,
    "HTC": 0x0BB4,
    "ASUS": 0x0B05,
}

# RNDIS communication interface variants used by Android.
INTERFACE_CLASSES = {
    "Wireless": (0xE0, 0x01, 0x03),
    "CDC": (0x02, 0x02, 0xFF),
}

BUNDLE_ID = "$(PRODUCT_BUNDLE_IDENTIFIER)"
DRIVER_DIR = Path(__file__).resolve().parent.parent


def personalities():
    result = {}
    for vendor_name, vendor_id in VENDORS.items():
        for variant, (cls, subclass, proto) in INTERFACE_CLASSES.items():
            key = f"AndroidRNDIS-{vendor_name.replace(' ', '').replace('/', '-')}-{variant}"
            result[key] = {
                "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleIdentifierKernel": "com.apple.kpi.iokit",
                "IOClass": "IOUserNetworkEthernet",
                "IOProviderClass": "IOUSBHostInterface",
                "IOUserClass": "AndroidRNDISDriver",
                "IOUserServerName": BUNDLE_ID,
                "IOProbeScore": 1000,
                "idVendor": vendor_id,
                "bInterfaceClass": cls,
                "bInterfaceSubClass": subclass,
                "bInterfaceProtocol": proto,
            }
    return result


def main():
    info = {
        "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSHumanReadableCopyright": "Copyright © 2026 Ali Edkymish",
        "OSBundleUsageDescription": "Provides a native Ethernet interface for Android USB tethering (RNDIS).",
        "IOKitPersonalities": personalities(),
    }
    entitlements = {
        "com.apple.developer.driverkit": True,
        "com.apple.developer.driverkit.family.networking": True,
        "com.apple.developer.driverkit.transport.usb": [{"idVendor": v} for v in VENDORS.values()],
    }
    with open(DRIVER_DIR / "Info.plist", "wb") as f:
        plistlib.dump(info, f, sort_keys=True)
    with open(DRIVER_DIR / "AndroidRNDISDriver.entitlements", "wb") as f:
        plistlib.dump(entitlements, f, sort_keys=True)
    print(f"Wrote {len(info['IOKitPersonalities'])} personalities for {len(VENDORS)} vendors")


if __name__ == "__main__":
    main()
