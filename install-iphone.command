#!/bin/zsh -l
# Builds APRSERJi for iPhone/iPad (signed with your team), installs it on each connected device and launches it.
cd ~/src/APRSERJi
LOG=.cbuild/iphone.log
{
  echo "== devices =="
  xcrun devicectl list devices
  echo "== build =="
  xcodebuild -project APRSERJi.xcodeproj -scheme APRSERJi-iOS -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath build/DeviceDD -allowProvisioningUpdates build \
    > .cbuild/xcode-device.log 2>&1
  grep -E 'error:|BUILD (SUCCEEDED|FAILED)' .cbuild/xcode-device.log | sort -u | head -40
  APP=$(ls -d build/DeviceDD/Build/Products/Debug-iphoneos/*.app | head -1)
  echo "app: $APP"
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' -c 'Print CFBundleVersion' "$APP/Info.plist"
  echo "== install =="
  xcrun devicectl list devices --json-output /tmp/aprserji-devices.json >/dev/null 2>&1
  for id in $(python3 -c 'import json;d=json.load(open("/tmp/aprserji-devices.json"))
for x in d["result"]["devices"]:
  if x.get("hardwareProperties",{}).get("platform")=="iOS" and x.get("hardwareProperties",{}).get("reality")=="physical" and x.get("connectionProperties",{}).get("tunnelState")!="unavailable": print(x["identifier"])'); do
    echo "-- device $id"
    xcrun devicectl device install app --device "$id" "$APP" && \
    xcrun devicectl device process launch --device "$id" com.kc9kko.APRSERJi
  done
  echo "== finished =="
} 2>&1 | tee $LOG
