#!/bin/zsh
# Screenshot tour of APRSERJi: walks the Mac app, the iPhone and iPad apps (simulators) and the Apple Watch app
# (simulator) through every tab, panel, tool and Setup section with made-up demo data around Goose Lake Prairie
# State Natural Area, saves a JPEG of each into docs/tour/{mac,iphone,ipad,watch}, writes docs/tour/README.md
# and updates the "Application tour" section of README.md.
#
# Usage: ./tour.sh                 all four
#        ./tour.sh mac iphone      only some of them
#
# Needs Xcode with the iOS and watchOS simulators. Mac screenshots come from screencapture when Terminal may
# record the screen (System Settings > Privacy & Security > Screen & System Audio Recording), otherwise from
# the app itself.
# Your own settings and messages aren't touched: the Mac tour runs a copy of the app under its own identity
# (com.kc9kko.APRSERJi.tour) and every tour keeps its demo messages in a separate folder.
set -uo pipefail
cd ~/src/APRSERJi
OUT=docs/tour
DD=build/TourDD
PORT=14590
STATUS=/tmp/aprserji-tour
MACAPP=/tmp/APRSERJi-Tour.app
TARGETS=(${@:-mac iphone ipad watch})
ARGS=(-TourMode YES -callsign KC9KKO -enableSending YES -useMetric NO
      -beaconEnabled YES -beaconSource "Fixed position" -notifyMessages NO)
LOG=build/tour.log
mkdir -p build "$OUT"
: > $LOG

say() { print -P "%B$1%b"; }

# The demo APRS-IS server, for as long as this script runs.
python3 tour/tour-server.py $PORT >> $LOG 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

# Steps through one device's scenes: waits for each new scene in <folder>/scene.txt, captures it with
# <capture> <file.png> [window id], turns it into a JPEG at most <size> pixels on its long side, and acks it.
shoot() {
  local folder=$1 out=$2 capture=$3 size=$4 last=-2 idx name wid
  mkdir -p "$out"
  find "$out" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.png' -o -name 'scenes.tsv' \) -delete
  local deadline=$((SECONDS + 1200))
  while (( SECONDS < deadline )); do
    if [ -f "$folder/scene.txt" ] && IFS=$'\t' read -r idx name wid < "$folder/scene.txt" && [[ -n "$idx" && "$idx" != "$last" && "$idx" != -1 ]]; then
      [[ "$name" == done ]] && break
      sleep 1.5
      local png="$out/$name.png"
      if $capture "$png" "${wid:-}" 2>>$LOG && [ -s "$png" ]; then
        sips -Z $size -s format jpeg -s formatOptions 82 "$png" --out "$out/$name.jpg" >/dev/null 2>&1
        find "$out" -maxdepth 1 -type f -name "$name.png" -delete
        echo "   $name"
      else
        echo "   $name: screenshot failed (see $LOG)"
      fi
      echo "$idx" > "$folder/ack.txt"
      last=$idx
    fi
    sleep 0.3
  done
  [ -f "$folder/scenes.tsv" ] && cp "$folder/scenes.tsv" "$out/scenes.tsv"
}

# The window via screencapture (needs Terminal allowed to record the screen), or else the picture the app took
# of its own window just before announcing the scene.
mac_capture() {
  screencapture -o -x -l"$2" "$1" 2>/dev/null && [ -s "$1" ] && return 0
  [ -s $STATUS/current.png ] && cp $STATUS/current.png "$1"
}

tour_mac() {
  say "== Mac =="
  echo "Building..."
  xcodebuild -project APRSERJi.xcodeproj -scheme APRSERJi-macOS -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath $DD build CODE_SIGNING_ALLOWED=NO >> $LOG 2>&1 || { echo "Mac build failed (see $LOG)"; return 1; }
  osascript -e 'quit app id "com.kc9kko.APRSERJi.tour"' >/dev/null 2>&1
  [ -d $MACAPP ] && mv $MACAPP $MACAPP.old.$$
  ditto $DD/Build/Products/Debug/APRSERJi-macOS.app $MACAPP
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.kc9kko.APRSERJi.tour' $MACAPP/Contents/Info.plist
  codesign --force --deep -s - $MACAPP >> $LOG 2>&1
  mkdir -p $STATUS
  find $STATUS -maxdepth 1 -type f -delete
  open -n $MACAPP --args "${ARGS[@]}"
  echo "Taking screenshots..."
  shoot $STATUS $OUT/mac mac_capture 2000
  osascript -e 'quit app id "com.kc9kko.APRSERJi.tour"' >/dev/null 2>&1
}

# A simulator's UDID: the first available device whose name matches one of the patterns, in order.
sim_udid() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = [d for runtime, ds in json.load(sys.stdin)["devices"].items() for d in ds if d.get("isAvailable")]
for pattern in sys.argv[1:]:
    hits = [d for d in devices if re.fullmatch(pattern, d["name"])]
    if hits:
        print(hits[-1]["udid"]); break' "$@"
}

IOS_BUILT=""
ios_build() {
  [ -n "$IOS_BUILT" ] && return 0
  echo "Building for the simulators..."
  xcodebuild -project APRSERJi.xcodeproj -scheme APRSERJi-iOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD build CODE_SIGNING_ALLOWED=NO >> $LOG 2>&1 \
    || { echo "Simulator build failed (see $LOG)"; return 1; }
  IOS_BUILT=1
}

sim_prepare() {
  local udid=$1
  xcrun simctl boot $udid >/dev/null 2>&1
  xcrun simctl bootstatus $udid -b >/dev/null 2>&1
  xcrun simctl ui $udid appearance light >/dev/null 2>&1
  xcrun simctl status_bar $udid override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 >/dev/null 2>&1
}

SIM=""
sim_capture() { xcrun simctl io $SIM screenshot --type=png "$1" >/dev/null 2>&1; }

tour_sim() {  # <label> <folder name> <bundle id> <app path> <jpeg size> <name patterns...>
  local label=$1 dir=$2 bundle=$3 app=$4 size=$5; shift 5
  say "== $label =="
  local udid=$(sim_udid "$@")
  [ -n "$udid" ] || { echo "No $label simulator found. Add one in Xcode (Window > Devices and Simulators)."; return 1; }
  echo "Simulator: $udid"
  sim_prepare $udid
  xcrun simctl terminate $udid $bundle >/dev/null 2>&1
  xcrun simctl uninstall $udid $bundle >/dev/null 2>&1
  xcrun simctl install $udid "$app" >> $LOG 2>&1 || { echo "Install failed (see $LOG)"; return 1; }
  xcrun simctl launch $udid $bundle "${ARGS[@]}" >> $LOG 2>&1 || { echo "Launch failed (see $LOG)"; return 1; }
  local data="$(xcrun simctl get_app_container $udid $bundle data)/Documents"
  echo "Taking screenshots..."
  SIM=$udid
  shoot "$data" $OUT/$dir sim_capture $size
  xcrun simctl terminate $udid $bundle >/dev/null 2>&1
  xcrun simctl status_bar $udid clear >/dev/null 2>&1
}

tour_iphone() {
  ios_build || return 1
  tour_sim "iPhone" iphone com.kc9kko.APRSERJi $DD/Build/Products/Debug-iphonesimulator/APRSERJi-iOS.app 1400 \
    'iPhone 1[0-9] Pro Max' 'iPhone 1[0-9] Pro' 'iPhone.*'
}

tour_ipad() {
  ios_build || return 1
  tour_sim "iPad" ipad com.kc9kko.APRSERJi $DD/Build/Products/Debug-iphonesimulator/APRSERJi-iOS.app 1600 \
    'iPad Pro 13-inch.*' 'iPad Pro.*' 'iPad.*'
}

tour_watch() {
  ios_build || return 1
  local app=$DD/Build/Products/Debug-watchsimulator/APRSERJi-Watch.app
  [ -d $app ] || { echo "The Watch app wasn't built for the simulator (see $LOG)"; return 1; }
  if [ -z "$(sim_udid 'Apple Watch.*')" ]; then
    # Make a Watch simulator if a watchOS runtime is installed.
    local runtime=$(xcrun simctl list runtimes available | awk '/watchOS/ {print $NF}' | tail -1)
    local type=$(xcrun simctl list devicetypes | grep -o 'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra[^)]*' | tail -1)
    if [ -n "$runtime" ] && [ -n "$type" ]; then
      xcrun simctl create "Apple Watch Ultra (APRSERJi tour)" $type $runtime >> $LOG 2>&1
    else
      say "== Apple Watch =="
      echo "No watchOS simulator installed. Add watchOS in Xcode > Settings > Components, then run ./tour.sh watch"
      return 1
    fi
  fi
  tour_sim "Apple Watch" watch com.kc9kko.APRSERJi.watchkitapp $app 1000 'Apple Watch Ultra.*' 'Apple Watch.*'
}

for target in $TARGETS; do
  case $target in
    mac) tour_mac ;;
    iphone) tour_iphone ;;
    ipad) tour_ipad ;;
    watch) tour_watch ;;
    *) echo "Unknown: $target (use mac, iphone, ipad, watch)" ;;
  esac
done

say "== Writing docs/tour/README.md and the README section =="
python3 tour/tour-docs.py
if python3 -c "import reportlab, PIL" 2>/dev/null; then
  python3 tour/tour-checklist.py
else
  echo "Skipped docs/tour/Checklist.pdf (it needs: pip3 install reportlab pillow)"
fi
echo "Done. Open docs/tour/README.md to look through the tour."
