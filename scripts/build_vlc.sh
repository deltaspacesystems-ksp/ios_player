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

echo "== pod install"
pod install

echo "== build"
xcodebuild -workspace VLC.xcworkspace -scheme VLC-iOS-no-watch -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

echo "== package"
APP=$(find "$ROOT/build/Build/Products" -maxdepth 2 -name "*.app" | head -1)
echo "app: $APP"
cd "$ROOT"
rm -rf Payload Lumen-VLC.ipa
mkdir Payload
cp -R "$APP" Payload/
zip -qr Lumen-VLC.ipa Payload
ls -la Lumen-VLC.ipa
echo "** BUILD SUCCEEDED **"
