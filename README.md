# APRSERJi

Native APRS station map, two-way messaging and beaconing for iPhone, iPad and Mac.

This is KC9KKO's fork of [KJ4DXK's APRSERJi](https://github.com/kj4dxk/APRSERJi). It adds a station list, weather and object display, beaconing with GeniusBeaconing and SmartBeaconing, radio ports (network TNCs on every device; serial, Bluetooth Classic and Bluetooth LE TNCs on the Mac) with an IGate and digipeater, routed two-way messaging, objects and scheduled bulletins, telemetry, a weather station with Tempest and CWOP support, satellite tracking, map layers, offline maps, WHO-IS callsign lookups, multi-area receive ranges and Keychain passcode storage — including the features of KJ4DXK's Windows [APRSERJ64](https://github.com/kj4dxk/APRSERJ64). Many of these follow KJ4ERJ's [APRSISCE/32](https://aprsisce.wikidot.com/start). The SwiftUI app runs on the same pinned Kotlin [aprs-core](https://github.com/kj4dxk/aprs-core) engine as APRSERJ64 on Windows and APRSERJa on Android, which provides the APRS-IS session, packet decoding, beacon policy, KISS/AGWPE codecs, and SQLite chat and outbox logic. See the [cross-platform audit and Apple architecture](docs/architecture.md), and [docs/APRSERJi.pdf](docs/APRSERJi.pdf) for the full change summary and source listings.

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
- **Layers**: paths of travel for other stations, dead reckoning (a dashed line to where a moving station should be now), PHG coverage circles, range rings around you, NWS warning areas (storm polygons, plus zone and county outlines for alerts at your location and APRS NWS bulletins), station labels and your nicknames, the route each RF packet took (station → digipeaters → IGate), direction-finding beams, radio horizons for aircraft and balloons, ambiguous positions as shaded cells, multiline and area objects, satellite footprints, and a NEXRAD weather radar overlay with adjustable opacity.
- The **🔍 menu** on the map: **Go to** a latitude/longitude, grid square or callsign; **Measure** the distance and bearing between two points (set A and B at the map center); **MultiTrack** (up to eight small maps, each following a station); and the radar overlay.
- **Tiles** defaults to the maintainer's **pdeffenb** server; **OpenStreetMap** uses the public tiles. **Start GPS** plots your position and breadcrumb trail while the app is open.

### Receive ranges

The feed receives stations around your current GPS fix, your last known GPS fix (kept across launches) and the map center, each with its own **Range (mi)** (1–1000 miles, default 500). Select **Apply** to use new ranges while connected. Points within 50 miles share one circle with the larger range. If you move or pan more than half a range outside the covered areas, the app reconnects with updated areas, at most every two minutes. The engine keeps up to 2,000 stations.

### View settings

Under the ranges in the map's settings panel, **View** filters what the map shows: stations, weather stations, objects and items; moving stations only; hiding digipeaters and gateways; stations heard on APRS-IS or RF only; heard within a number of minutes; and within a distance of you. **Always show** takes up to twelve callsigns, such as `KJ4DXK*, KC9KKO*, W9ABC-9` (end with `*` to match any SSID); the field scrolls with the arrow keys. They are added to the APRS-IS filter as a buddy list (`b/`), so their packets arrive even far outside your receive ranges; they bypass the View filters and are marked in yellow. All View settings are kept across restarts.

### Stations

A searchable list of everything heard on APRS-IS and RF, filtered by stations, weather or objects and sorted by distance, last heard or callsign. Station details show position, grid square, distance and bearing, movement, the weather report, telemetry (PARM names, UNITs, EQNS scaling and named BITS), owner, path, packet count and PHG coverage, with **Message**, **Show on map** and **WHO-IS**.

### Messages

Two-way messaging with acknowledgments and retries, over APRS-IS, the radio, or both. Each conversation has a route — **Best** (the radio when the station was heard there recently, otherwise APRS-IS), **Radio only** or **APRS-IS only** — and an acknowledgment switch. Messages up to 300 characters are split into numbered parts, each acknowledged on its own. **Queue** saves a message even while disconnected; the outbox survives restarts. Messages that weren't acknowledged can be retried, and the location button inserts your position and grid square. New messages raise a notification and an unread badge; tapping the notification opens the conversation. Tools ▸ **Send email** sends through an APRS email gateway (EMAIL-2), splitting long mail into numbered parts.

### Bulletins

NWS alerts for your location (from api.weather.gov), APRS bulletins (BLN…, NWS-…) heard in range, and ANSRVR announcement groups: join or leave a group, send a CQ to it, ask which groups you're in or list them, see which memberships ANSRVR confirmed, and keep your groups alive by rejoining every six hours.

### Tools

- **Objects, items & bulletins**: publish objects and items (fixed or following your position), with frequency objects (`146.940MHz T107 -060 R25`), lines and areas drawn as AE5PL multilines, kill and revive, and QRU groups. Schedule bulletins (BLN0–BLNZ, with an optional group), and send QRU queries.
- **Beacon journal** (every report this station sent, why and where) and **Packet monitor** (every packet heard and sent per port, with pause, search and export).
- **Frequencies** advertised by nearby stations, **Platforms** (the radio or software behind each station, from the aprs.fi device identification database), **RF DX** (stations heard directly on RF, farthest first) and **Station history** (archived tracks with GPX export, altitude and telemetry graphs).
- **Satellites**: amateur satellite elements from CelesTrak, tracked with SGP4 — live positions, footprints and pass predictions.
- **Direction finding** bearings, **digital-mode logs** (WSJT-X FT8, JS8Call, JT65-HF stations placed at their grid squares) and **GPX / OpenStreetMap** layer imports.

### Setup

- **Beacon**: GPS or fixed position, any symbol from both APRS tables (with overlays), comment (60 characters) and timing. **Fixed interval** beacons every 1–60 minutes. **GeniusBeaconing** beacons when your position strays from where your last beacon's course and speed predicted, after a distance traveled or a heading change. **SmartBeaconing** beacons faster with speed and on turns (corner pegging). **Report format** offers Mic-E (with its status), compressed reports, position ambiguity, DAO extra precision and timestamps. Beacons go out over a verified APRS-IS login and on every radio port set to send beacons.
- **Status and telemetry**: a status report on a schedule, and your own telemetry (packets heard, digipeated and gated, messages, stations, uptime) with channel names, units and scaling.
- **Radio ports**: Dire Wolf, UZ7HO Sound Modem, AGWPE or a network KISS TNC (KISS, AGWPE or TEXT/TNC2 monitor), found automatically on the network. On the Mac, a workspace of named ports adds serial/USB TNCs (KISS, Kenwood, TNC2), Bluetooth Classic (SPP) and Bluetooth LE KISS TNCs (Mobilinkd TNC3/4, BTECH UV-PRO, ESP32/Nordic UART), and an ISS/ARISS preset. Each port can transmit or listen only, send your beacons, **digipeat** (WIDE1-1 fill-in or wide-area transforms, also onto other ports), and **IGate** both ways: RF to APRS-IS, and APRS-IS messages (plus callsigns, objects or a javAPRSFilter you choose) to RF.
- **GPS (Mac)**: Location Services, a serial NMEA GPS, network NMEA or gpsd, with a satellite sky plot.
- **Weather station**: a WeatherFlow **Tempest** (local network broadcasts, or the WeatherFlow cloud with your token), a web address or file (wxnow.txt or JSON), or a Peet Bros Ultimeter on a serial port (Mac). Send your readings as your station or a weather object, and upload them to **CWOP**.
- **Automatic answers**: standard APRS queries (?APRS?, ?APRSP, ?PING?, ?VER, ?IGATE…), an away message with loop protection, a QRU object server and an information kiosk.
- **Services**: APRS-IS backup servers, a local APRS-IS server for other programs (Xastir, YAAC…), UDP packet input, a syslog copy, station history retention, daily GPX/CSV track logs, and watched-station alerts (nearby, or gone quiet) with sounds.
- **Map layers**, **Offline maps** and **Callsign lookup** (below), and **Display & alerts**: metric units, message notifications and, on the Mac, **Reset window size**. The Mac window keeps its size and position across restarts; **Window ▸ Reset Window Size** (⌥⌘0) returns it to its normal size.

### Offline maps

Every tile the map shows is cached on the device and used whenever the network is unavailable, up to a size limit you choose (least recently used tiles go first). **Download visible map area** fetches the area on screen for the current and deeper zoom levels (up to 5,000 tiles) from the pdeffenb server. The [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/) forbids bulk downloads, so preloading is not offered for OpenStreetMap tiles.

### WHO-IS callsign lookup

Looks up a station's license holder, class and expiration via callook.info, then HamDB, then an optional downloaded copy of the FCC amateur license database (Setup ▸ Callsign lookup, `l_amat.zip` from data.fcc.gov, over 100 MB). US callsigns only; QRZ.com and aprs.fi links are always offered.

## Software modem quick start

| Modem | KISS-TCP port | AGWPE port |
|---|---|---|
| Dire Wolf | 8001 | 8000 |
| UZ7HO Sound Modem | 8100 | 8000 |
| AGWPE | — | 8000 |

Use host `127.0.0.1` when the modem runs on the same Mac, or the modem computer's address from an iPhone or iPad (iOS asks for local network access). Dire Wolf advertises itself on the network, so **Find network KISS TNCs** fills in its address. Transmitting on RF, digipeating and gating require a licensed operator.

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

APRS-IS servers (default `rotate.aprs2.net`), map tiles from the pdeffenb server or OpenStreetMap, NWS alerts and zone outlines from [api.weather.gov](https://www.weather.gov/documentation/services-web-api), NEXRAD radar tiles from [Iowa Environmental Mesonet](https://mesonet.agron.iastate.edu/ogc/), satellite elements from [CelesTrak](https://celestrak.org), device identification from [aprs-deviceid](https://github.com/aprsorg/aprs-deviceid) (© OH7LZB, CC BY-SA 2.0), Tempest readings from [WeatherFlow](https://weatherflow.github.io/Tempest/api/), callsign data from [callook.info](https://callook.info), [HamDB](https://hamdb.org) and the [FCC ULS](https://www.fcc.gov/uls/transactions/daily-weekly) amateur database. Your passcode stays in the Keychain; chat history, GPS tracks, map tiles and the FCC database stay on the device.

## License and credits

APRSERJi and aprs-core are licensed under AGPL-3.0. The app and shared engine are by KJ4DXK and are based on APRSIS32 and APRSISMO by Lynn Deffenbaugh, KJ4ERJ (SK). Fork additions by KC9KKO; the WHO-IS lookup is ported from KC9KKO's Club Members app.
