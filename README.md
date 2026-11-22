# APRSERJi

Native APRS station map for iPhone, iPad, and Mac. The first milestone is a receive-only APRS-IS map with a configurable server. Move the map to the area you want to monitor, enter your callsign, and select **Connect**. The feed uses a 100 km filter centered on the map when you connect.

The SwiftUI app uses MapKit and links the Kotlin APRS engine also used by APRSERJ64 on Windows. APRSERJa is the standalone Android companion. The APRS-IS session, wire formats, and station cache come from the pinned [aprs-core](https://github.com/kj4dxk/aprs-core) submodule. See the [cross-platform audit and Apple architecture](docs/architecture.md) for the path to Android feature parity.

[Windows · APRSERJ64](https://github.com/kj4dxk/APRSERJ64) · [Android · APRSERJa](https://github.com/kj4dxk/APRSERJa)

## Getting started

APRSERJi is available as source code. This project does not currently offer an App Store download, a public TestFlight link, or a signed iPhone/iPad installer. You can build and run it directly from Xcode without going through the App Store. The [Apple build workflow](https://github.com/kj4dxk/APRSERJi/actions/workflows/apple.yml) checks compilation for macOS, iOS Simulator, and the generic iOS device target. The device build runs without signing. Physical-device verification still requires a signed install followed by launching the app and confirming that stations appear on the map.

### Build on a Mac

Use a Mac running macOS Tahoe 26.2 or later with Xcode 26.4, JDK 17, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). With Homebrew, install XcodeGen with `brew install xcodegen`. Open Xcode once to complete its setup and install iOS platform support if prompted. [Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)

```sh
git clone --recurse-submodules https://github.com/kj4dxk/APRSERJi.git
cd APRSERJi
./gradlew assembleAprsCoreReleaseXCFramework
xcodegen generate
open APRSERJi.xcodeproj
```

- **Mac** — Select the **APRSERJi-macOS** scheme and **My Mac**, then choose **Run**. The app targets macOS 14 or later. You can run the local build without setting up an Apple developer team.
- **iPhone or iPad Simulator** — Select **APRSERJi-iOS**, choose an iPhone or iPad simulator, and select **Run**. Install a simulator runtime in Xcode if no simulator appears. Simulator builds require no provisioning. [Apple's guide to running apps in Xcode](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

### Run on your own iPhone or iPad

1. Use an iPhone or iPad running iOS or iPadOS 17 or later. Connect it to the Mac, unlock it, and trust the Mac when prompted.
2. In **Xcode → Settings → Apple Accounts**, sign in with your Apple Account. A free **Personal Team** works for local testing. In the **APRSERJi-iOS** target's **Signing & Capabilities** pane, enable **Automatically manage signing** and select your team. If Xcode cannot register the default bundle identifier, replace it with a unique identifier you control, such as `com.yourname.aprserji`.
3. Select the connected device as the run destination. When Xcode prompts you, open **Settings → Privacy & Security → Developer Mode** on the device, enable it, restart, and confirm after the restart. Then select **Run** in Xcode. [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
4. With a free Personal Team, the provisioning profile expires after seven days. Run the app from Xcode again to rebuild and reinstall it. [Apple's Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account/)

Installing on an iPhone or iPad without a Mac requires a distributed build. TestFlight or App Store distribution requires the maintainer to enroll in the Apple Developer Program and publish through Apple. [Apple's distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)

APRSERJi and aprs-core are licensed under AGPL-3.0. The shared engine is based on APRSIS32 and APRSISMO.
