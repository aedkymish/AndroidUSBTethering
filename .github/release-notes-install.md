
## Install

With Homebrew:

```bash
brew tap aedkymish/androidusbtethering https://github.com/aedkymish/AndroidUSBTethering
brew trust aedkymish/androidusbtethering
brew install --cask android-usb-tethering
```

Or manually:

1. Download **AndroidUSBTethering-VERSION.dmg**, open it and drag the app to **Applications**.
2. Open the app once. The build is ad-hoc signed and **not notarized** (no paid Apple Developer
   account), so macOS blocks it the first time. Go to **System Settings → Privacy & Security** and
   click **Open Anyway**. Or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/AndroidUSBTethering.app
   ```
3. In the menu bar icon, click **Install Helper** and allow it in **System Settings → General → Login
   Items**. If macOS refuses to register it, the app shows a Terminal command. You can also run it
   yourself:
   ```bash
   sudo sh "/Applications/AndroidUSBTethering.app/Contents/Resources/Scripts/install-helper.sh"
   ```
   Run it again after each update.
4. Connect the phone and turn on **USB tethering**, or click **Turn On** in the app's ADB section.

Verify the download with `shasum -a 256 -c SHA256SUMS.txt`.

> This is an early pre-release. It is built and unit-tested in CI but has not been verified on many
> Mac and phone combinations yet. Please report your results in Issues.
