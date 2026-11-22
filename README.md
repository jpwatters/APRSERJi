# APRSERJi

Native APRS station map for iPhone, iPad, and Mac. The first milestone is a receive-only APRS-IS map with a configurable server. Move the map to the area you want to monitor, enter your callsign, and select **Connect**. The feed uses a 100 km filter centered on the map when you connect.

The SwiftUI app uses MapKit and links the Kotlin APRS engine also used by APRSERJ64 on Windows. APRSERJa is the standalone Android companion. The APRS-IS session, wire formats, and station cache come from the pinned [aprs-core](https://github.com/kj4dxk/aprs-core) submodule. See the [cross-platform audit and Apple architecture](docs/architecture.md) for the path to Android feature parity.

## Build on a Mac

Use Xcode 26.4, JDK 17, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). With Homebrew, install the generator with `brew install xcodegen`.

```sh
git clone --recurse-submodules https://github.com/kj4dxk/APRSERJi.git
cd APRSERJi
./gradlew assembleAprsCoreReleaseXCFramework
xcodegen generate
open APRSERJi.xcodeproj
```

Select **APRSERJi-macOS** or **APRSERJi-iOS**. Select an iOS simulator to run without provisioning. For a physical device, choose a signing team and a bundle identifier you control. The minimum deployment targets are iOS/iPadOS 17 and macOS 14.

APRSERJi and aprs-core are licensed under AGPL-3.0. The shared engine is based on APRSIS32 and APRSISMO.
