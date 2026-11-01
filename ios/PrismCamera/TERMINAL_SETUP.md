# Terminal setup and physical-iPhone run

The current Mac has only `/Library/Developer/CommandLineTools`. That package can compile the desktop engine, but it does not contain the iPhone SDK, ARKit, RealityKit, device support, or `devicectl`. A full Xcode installation is required.

## 1. Install full Xcode

The shortest terminal route uses the Mac App Store command-line client. Sign into the Mac App Store once, then run:

```sh
brew install mas
mas install 497799835
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS
xcodebuild -version
xcode-select --print-path
```

The final path must be `/Applications/Xcode.app/Contents/Developer`, rather than `/Library/Developer/CommandLineTools`.

If `mas` cannot download Xcode for the signed-in App Store account, install Xcode from the Mac App Store and resume at `xcode-select`; the rest of the workflow stays in Terminal.

## 2. Perform Apple's one-time device and signing steps

Connect the iPhone by cable, unlock it, tap **Trust**, and enable **Settings → Privacy & Security → Developer Mode** on the phone. The phone restarts. These security prompts cannot be accepted from the Mac terminal.

Check that CoreDevice sees it:

```sh
xcrun devicectl list devices
```

Automatic signing also needs an Apple Development identity. Check for one:

```sh
security find-identity -v -p codesigning
```

If no `Apple Development` identity appears, open the account pane once:

```sh
open -a Xcode
```

In Xcode, use **Settings → Accounts**, sign in, and select **Manage Certificates → + → Apple Development**. Quit Xcode afterward. A free Personal Team is enough for local device testing, although its provisioning expires more frequently.

## 3. Build, install, and launch

List the phone name:

```sh
xcrun devicectl list devices
```

Then use the included runner, replacing the example name and team identifier:

```sh
cd /path/to/PrismEngine/ios/PrismCamera
chmod +x run-on-device.sh
PRODUCT_BUNDLE_IDENTIFIER=com.yourdomain.spectral DEVELOPMENT_TEAM=YOURTEAMID ./run-on-device.sh "Your iPhone"
```

The script builds for that physical device, requests automatic provisioning, installs `PrismCamera.app`, and launches the bundle identifier you supplied.

To discover the ten-character team identifier from an existing certificate:

```sh
security find-identity -v -p codesigning
```

It is the value in parentheses at the end of an `Apple Development` identity. The runner attempts to detect it when `DEVELOPMENT_TEAM` is omitted, so this may also work:

```sh
PRODUCT_BUNDLE_IDENTIFIER=com.yourdomain.spectral ./run-on-device.sh "Your iPhone"
```

## 4. Use the app

Accept camera access on the iPhone. Move slowly for several seconds so ARKit can estimate surfaces and lighting. Tap a horizontal surface to place the crystal. In Touch mode, drag to move and use two fingers to scale or rotate. Hands mode uses a thumb/index pinch over the crystal and releases when the hand opens. LiDAR supplies registered scene depth for occlusion and screen-space optical sampling.

The simulator is useful for compile checks but cannot validate the camera, depth, real lighting, or placement quality required by this demo.
