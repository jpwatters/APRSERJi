# APRSERJi

Native APRS station map, two-way messaging and beaconing for iPhone, iPad and Mac.

This is KC9KKO's fork of [KJ4DXK's APRSERJi](https://github.com/kj4dxk/APRSERJi). It adds a station list, weather and object display, beaconing with GeniusBeaconing, software modem (RF) support with an IGate, bulletins and ANSRVR announcements, telemetry, map layers, offline maps, WHO-IS callsign lookups, multi-area receive ranges and Keychain passcode storage. Many of these follow KJ4ERJ's [APRSISCE/32](https://aprsisce.wikidot.com/start). The SwiftUI app runs on the same pinned Kotlin [aprs-core](https://github.com/kj4dxk/aprs-core) engine as APRSERJ64 on Windows and APRSERJa on Android, which provides the APRS-IS session, packet decoding, beacon policy, KISS/AGWPE codecs, and SQLite chat and outbox logic. See the [cross-platform audit and Apple architecture](docs/architecture.md), and [docs/APRSERJi.pdf](docs/APRSERJi.pdf) for the full change summary and source listings.

[Windows · APRSERJ64](https://github.com/kj4dxk/APRSERJ64) · [Android · APRSERJa](https://github.com/kj4dxk/APRSERJa)

## Getting started

1. Enter your callsign. Pan the map to the area you want to monitor.
2. To send messages and beacons, select **Enable sending** and enter your APRS-IS passcode. Connections without a passcode are receive-only.
3. Select **Connect**. The status changes to **Verified** when the server accepts the passcode; the line under it shows the server's login response.

Once the server verifies a passcode, the app saves it in the system Keychain (encrypted, one entry per base callsign, never re-prompted on a signed Mac build) and uses it on later connections. Type a new passcode to replace it after it verifies, or select **Forget** to remove it. With a verified passcode saved, the app connects by itself 15 seconds after launch: click the countdown to pause or resume it, **Connect now** to skip the wait, or **Cancel** to stay offline.

## Features

### Map

- The map fills the window. A floating bar shows the connection status, the number of stations on the map, GPS and Follow buttons, and a settings button that opens the connection, tile, layer and range settings.
- Station markers show the APRS symbol and are colored by kind: red stations, teal weather stations, orange objects, purple items and yellow watched stations. The **View** settings choose which stations appear.
- Click a station for an information bubble: time heard, comment, weather or movement, owner, path (APRS-IS or RF), PHG coverage, distance and grid square from you, and **zoom**, **details**, **message** and **who-is** links.
- **Layers**: paths of travel for other stations, dead reckoning (a dashed line to where a moving station should be now), PHG coverage circles, range rings around you, and NWS warning areas.
- **Tiles** defaults to the maintainer's **pdeffenb** server; **OpenStreetMap** uses the public tiles. **Start GPS** plots your position and breadcrumb trail while the app is open.

### Receive ranges

The feed receives stations around your current GPS fix, your last known GPS fix (kept across launches) and the map center, each with its own **Range (mi)** (1–1000 miles, default 500). Select **Apply** to use new ranges while connected. Points within 50 miles share one circle with the larger range. If you move or pan more than half a range outside the covered areas, the app reconnects with updated areas, at most every two minutes. The engine keeps up to 2,000 stations.

### View settings

Under the ranges in the map's settings panel, **View** filters what the map shows: stations, weather stations, objects and items; moving stations only; hiding digipeaters and gateways; stations heard on APRS-IS or RF only; heard within a number of minutes; and within a distance of you. **Always show** takes up to twelve callsigns, such as `KJ4DXK*, KC9KKO*, W9ABC-9` (end with `*` to match any SSID); the field scrolls with the arrow keys. They are added to the APRS-IS filter as a buddy list (`b/`), so their packets arrive even far outside your receive ranges; they bypass the View filters and are marked in yellow. All View settings are kept across restarts.

### Stations

A searchable list of everything heard on APRS-IS and RF, filtered by stations, weather or objects and sorted by distance, last heard or callsign. Station details show position, grid square, distance and bearing, movement, the weather report, telemetry (PARM names, UNITs, EQNS scaling and named BITS), owner, path, packet count and PHG coverage, with **Message**, **Show on map** and **WHO-IS**.

### Messages

Two-way messaging with acknowledgments and retries. **Queue** saves a message even while disconnected; the outbox survives restarts and resumes after a verified connection with the same callsign and SSID. New messages raise a notification and an unread badge; tapping the notification opens the conversation.

### Bulletins

NWS alerts for your location (from api.weather.gov), APRS bulletins (BLN…, NWS-…) heard in range, and ANSRVR announcement groups: join or leave a group, send a CQ to it and read announcements.

### Setup

- **Beacon**: GPS or fixed position, symbol, comment (43 characters) and timing. **Fixed interval** beacons every 1–60 minutes. **GeniusBeaconing** beacons when your position strays from where your last beacon's course and speed predicted, after a distance traveled or a heading change, within minimum and maximum intervals. Beacons carry course, speed and altitude from GPS, go out over a verified APRS-IS login and, with **Also send on RF**, through the software modem with your chosen path. GPS starts automatically when beaconing from GPS.
- **Radio**: connect to Dire Wolf, UZ7HO Sound Modem or AGWPE over KISS-TCP or AGWPE. Stations heard on RF join the map and lists even without APRS-IS. The optional **IGate** gates RF packets to APRS-IS while the login is verified.
- **Map layers**, **Offline maps** and **Callsign lookup** (below), and **Display & alerts**: metric units, message notifications and, on the Mac, **Reset window size**. The Mac window keeps its size and position across restarts; **Window ▸ Reset Window Size** (⌥⌘0) returns it to its normal size.

### Offline maps

Every tile the map shows is cached on the device and used whenever the network is unavailable. **Download visible map area** fetches the area on screen for the current and deeper zoom levels (up to 5,000 tiles) from the pdeffenb server. The [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/) forbids bulk downloads, so preloading is not offered for OpenStreetMap tiles.

### WHO-IS callsign lookup

Looks up a station's license holder, class and expiration via callook.info, then HamDB, then an optional downloaded copy of the FCC amateur license database (Setup ▸ Callsign lookup, `l_amat.zip` from data.fcc.gov, over 100 MB). US callsigns only; QRZ.com and aprs.fi links are always offered.

## Software modem quick start

| Modem | KISS-TCP port | AGWPE port |
|---|---|---|
| Dire Wolf | 8001 | 8000 |
| UZ7HO Sound Modem | 8100 | 8000 |
| AGWPE | — | 8000 |

Use host `127.0.0.1` when the modem runs on the same Mac, or the modem computer's address from an iPhone or iPad (iOS asks for local network access). Transmitting on RF and gating require a licensed operator.

## Build on a Mac

Use macOS Tahoe 26.2 or later with Xcode 26.4 or later, JDK 17 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone --recurse-submodules https://github.com/jpwatters/APRSERJi.git
cd APRSERJi
./gradlew macosArm64Test assembleAprsCoreReleaseXCFramework
xcodegen generate
open APRSERJi.xcodeproj
```

Run `xcodegen generate` again after adding files, and the Gradle step after changing Kotlin code. The build reads the shared core directly from the pinned submodule. To pick up KJ4DXK's changes: `git remote add upstream https://github.com/kj4dxk/APRSERJi.git`, then `git fetch upstream && git merge upstream/main && git submodule update --init --recursive`.

**Signing.** `project.yml` signs with team `7Q943H255L` and bundle ID `com.kc9kko.APRSERJi`, and gives the Mac app a `keychain-access-groups` entitlement so the saved passcode is never re-prompted. To build under your own Apple developer account, change `DEVELOPMENT_TEAM` and both `PRODUCT_BUNDLE_IDENTIFIER` values (and the entitlement's bundle ID) in `project.yml`, then run `xcodegen generate`.

- **Mac**: select the **APRSERJi-macOS** scheme and **My Mac**, then **Run**. Targets macOS 14 or later.
- **iPhone or iPad Simulator**: select **APRSERJi-iOS** and a simulator, then **Run**.
- **Your own iPhone or iPad** (iOS/iPadOS 17 or later): connect it, select it as the run destination, enable **Developer Mode** when prompted (Settings ▸ Privacy & Security), then **Run**. With a free Personal Team the install expires after seven days. [Apple's guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

APRSERJi is available as source code only; there is no App Store or TestFlight build.

## Data sources

APRS-IS servers (default `rotate.aprs2.net`), map tiles from the pdeffenb server or OpenStreetMap, NWS alerts from [api.weather.gov](https://www.weather.gov/documentation/services-web-api), callsign data from [callook.info](https://callook.info), [HamDB](https://hamdb.org) and the [FCC ULS](https://www.fcc.gov/uls/transactions/daily-weekly) amateur database. Your passcode stays in the Keychain; chat history, GPS tracks, map tiles and the FCC database stay on the device.

## License and credits

APRSERJi and aprs-core are licensed under AGPL-3.0. The app and shared engine are by KJ4DXK and are based on APRSIS32 and APRSISMO by Lynn Deffenbaugh, KJ4ERJ (SK). Fork additions by KC9KKO; the WHO-IS lookup is ported from KC9KKO's Club Members app.
