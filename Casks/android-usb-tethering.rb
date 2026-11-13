cask "android-usb-tethering" do
  version "0.3.0"
  sha256 "ba70233f1cf691b700d79f04f1a07cadcec0c7d127ea789d268a3473e2a749fa"

  url "https://github.com/aedkymish/AndroidUSBTethering/releases/download/v#{version}/AndroidUSBTethering-#{version}.dmg"
  name "Android USB Tethering"
  desc "Use an Android phone's USB tethering (RNDIS or NCM) as a network connection"
  homepage "https://github.com/aedkymish/AndroidUSBTethering"

  depends_on macos: :ventura

  app "AndroidUSBTethering.app"

  uninstall launchctl: "com.aedkymish.AndroidUSBTethering.helper",
            quit:      "com.aedkymish.AndroidUSBTethering",
            delete:    [
              "/Library/LaunchDaemons/com.aedkymish.AndroidUSBTethering.helper.plist",
              "/Library/PrivilegedHelperTools/com.aedkymish.AndroidUSBTethering.helper",
            ]

  zap trash: [
    "/var/root/Library/Preferences/com.aedkymish.AndroidUSBTethering.helper.plist",
    "~/Library/Preferences/com.aedkymish.AndroidUSBTethering.plist",
  ]

  caveats <<~EOS
    #{token} is ad-hoc signed and not notarized, so macOS blocks its first launch.
    Allow it in System Settings → Privacy & Security → Open Anyway, or run:
      xattr -dr com.apple.quarantine #{appdir}/AndroidUSBTethering.app

    Then open the app and click "Install Helper" in its menu bar icon.
  EOS
end
