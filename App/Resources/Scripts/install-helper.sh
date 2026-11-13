#!/bin/sh
# Installs (or removes) the Android USB Tethering helper as a launchd daemon without SMAppService.
# Used when the app cannot register the helper itself (for example, ad-hoc signed releases).
#
#   sudo sh "/Applications/AndroidUSBTethering.app/Contents/Resources/install-helper.sh"
#   sudo sh "/Applications/AndroidUSBTethering.app/Contents/Resources/install-helper.sh" --uninstall
#
# The helper binary is copied to a root-owned location so that code running as root cannot be
# replaced from the user-writable app bundle.
set -eu

LABEL="com.aedkymish.AndroidUSBTethering.helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
TOOLS="/Library/PrivilegedHelperTools"
INSTALLED="$TOOLS/$LABEL"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

unload() {
    launchctl bootout "system/$LABEL" 2>/dev/null || true
}

if [ "${1:-}" = "--uninstall" ]; then
    unload
    rm -f "$PLIST" "$INSTALLED"
    echo "Helper removed."
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
SOURCE="$APP/Contents/MacOS/AndroidUSBTetheringHelper"

if [ ! -x "$SOURCE" ]; then
    echo "Helper not found at $SOURCE" >&2
    exit 1
fi
codesign --verify --strict "$APP" || { echo "The app's code signature is invalid." >&2; exit 1; }

unload
mkdir -p "$TOOLS"
install -o root -g wheel -m 755 "$SOURCE" "$INSTALLED"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED</string>
		<string>--app</string>
		<string>$APP</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>$LABEL</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
echo "Helper installed for $APP"
echo "Run this script again after updating the app."
