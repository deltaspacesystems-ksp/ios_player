#!/bin/bash
# Builds an unsigned IPA of upstream VLC for iOS (pinned) with the Lumen modifications applied.
set -euo pipefail
VLC_SHA=6e80b7616232f7419a19f1a10f74da539b077f51
ROOT="$(pwd)"
WORK="$ROOT/vlc-src"

echo "== clone vlc-ios @ $VLC_SHA"
rm -rf "$WORK"
git clone https://github.com/videolan/vlc-ios.git "$WORK"
cd "$WORK"
git checkout "$VLC_SHA"

echo "== versions"
xcodebuild -version
pod --version || true
ruby -v

echo "== rebrand + inject Lumen"
sed -i '' 's/^BUNDLE_IDENTIFIER_PREFIX=.*/BUNDLE_IDENTIFIER_PREFIX=dev.lumen/' Buildsystem/SharedConfig.xcconfig
cp -R "$ROOT/LumenKit" "$WORK/LumenKit"
which ruby gem pod
gem list -i xcodeproj >/dev/null 2>&1 || gem install xcodeproj --no-document --user-install
ruby "$ROOT/scripts/patch_vlc.rb" "$WORK"
xcodebuild -list -project VLC.xcodeproj | head -40

echo "== pod install"
pod install

echo "== build"
xcodebuild -workspace VLC.xcworkspace -scheme VLC-iOS-no-watch -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

echo "== package"
APP=$(find "$ROOT/build/Build/Products" -maxdepth 2 -name "*.app" | head -1)
echo "app: $APP"
echo "== rebrand app"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleIdentifier dev.lumen.player" "$APP/Info.plist"
$PB -c "Set :CFBundleDisplayName Lumen" "$APP/Info.plist"
$PB -c "Set :CFBundleName Lumen" "$APP/Info.plist"
$PB -c "Add :NSMicrophoneUsageDescription string Lumen listens through the microphone only when you ask it to identify a song with Shazam." "$APP/Info.plist" || true
cd "$ROOT"
rm -rf Payload Lumen-VLC.ipa
mkdir Payload
cp -R "$APP" Payload/
zip -qr Lumen-VLC.ipa Payload
# lighter variant without app extensions (share extension, widget) for sideload App ID limits
rm -rf Payload-lite && mkdir Payload-lite && cp -R "$APP" Payload-lite/
rm -rf Payload-lite/*.app/PlugIns
mv Payload-lite Payload-tmp && mkdir Payload-lite && mv Payload-tmp Payload-lite/Payload && (cd Payload-lite && zip -qr ../Lumen-VLC-noext.ipa Payload)
ls -la Lumen-VLC.ipa Lumen-VLC-noext.ipa
echo "** BUILD SUCCEEDED **"
