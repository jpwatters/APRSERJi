#!/bin/zsh -l
# Builds APRSERJi for iPhone/iPad and its Apple Watch companion (signed with your team), installs the
# iPhone app on each connected iPhone/iPad and launches it, and installs the Watch app on each paired Watch.
cd ~/src/APRSERJi
LOG=.cbuild/iphone.log
devices() {  # identifier,udid of each reachable physical device of platform $1
  python3 -c 'import json,sys;d=json.load(open("/tmp/aprserji-devices.json"))
for x in d["result"]["devices"]:
  h=x.get("hardwareProperties",{})
  if h.get("platform")==sys.argv[1] and h.get("reality")=="physical" and x.get("connectionProperties",{}).get("tunnelState")!="unavailable": print(x["identifier"]+","+h.get("udid",""))' "$1"
}
{
  echo "== devices =="
  xcrun devicectl list devices
  xcrun devicectl list devices --json-output /tmp/aprserji-devices.json >/dev/null 2>&1

  # The Watch app first: building it for each Watch registers that Watch with your developer account,
  # which the iPhone build (it carries the Watch app inside) needs for signing.
  WATCHES=($(devices watchOS))
  for line in $WATCHES; do
    id=${line%%,*}; udid=${line##*,}
    echo "== Apple Watch build ($udid) =="
    xcodebuild -project APRSERJi.xcodeproj -scheme APRSERJi-Watch -configuration Debug \
      -destination "id=$udid" -derivedDataPath build/DeviceDD \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > .cbuild/xcode-watch.log 2>&1
    grep -E 'error:|BUILD (SUCCEEDED|FAILED)' .cbuild/xcode-watch.log | sort -u | head -20
  done

  echo "== iPhone/iPad build =="
  xcodebuild -project APRSERJi.xcodeproj -scheme APRSERJi-iOS -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath build/DeviceDD -allowProvisioningUpdates build \
    > .cbuild/xcode-device.log 2>&1
  grep -E 'error:|BUILD (SUCCEEDED|FAILED)' .cbuild/xcode-device.log | sort -u | head -40
  APP=build/DeviceDD/Build/Products/Debug-iphoneos/APRSERJi-iOS.app
  echo "app: $APP"
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' -c 'Print CFBundleVersion' "$APP/Info.plist"

  echo "== install on iPhone/iPad =="
  for line in $(devices iOS); do
    id=${line%%,*}
    echo "-- device $id"
    xcrun devicectl device install app --device "$id" "$APP" && \
    xcrun devicectl device process launch --device "$id" com.kc9kko.APRSERJi
  done

  echo "== install on Apple Watch =="
  WAPP=build/DeviceDD/Build/Products/Debug-watchos/APRSERJi-Watch.app
  [ -d "$WAPP" ] || WAPP="$APP/Watch/APRSERJi-Watch.app"
  for line in $WATCHES; do
    id=${line%%,*}
    echo "-- watch $id"
    # A sleeping Watch often misses the first try; wake it (raise your wrist) and it gets a second one.
    xcrun devicectl device install app --device "$id" "$WAPP" || {
      echo "The Watch didn't answer; raise your wrist to wake it. Trying again in 20 seconds."
      sleep 20
      xcrun devicectl device install app --device "$id" "$WAPP"
    }
  done
  [ -n "$WATCHES" ] || echo "No paired Apple Watch is reachable (turn on Developer Mode on the Watch and keep it near the iPhone)."
  echo "== finished =="
} 2>&1 | tee $LOG
