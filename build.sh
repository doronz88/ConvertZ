#!/bin/sh
# Builds ConvertZ.app into ./build, with ffmpeg and ffprobe inside it. Apple Silicon only.
#   VERSION=1.2.0 ./build.sh     set CFBundleShortVersionString / CFBundleVersion
set -eu
cd "$(dirname "$0")"

Tools/fetch-ffmpeg.sh
swift build -c release --product ConvertZ --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/ConvertZ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/ConvertZ" "$APP/Contents/MacOS/ConvertZ"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/ffmpeg-LICENSE.txt THIRD-PARTY.md "$APP/Contents/Resources/"
cp vendor/ffmpeg/ffmpeg vendor/ffmpeg/ffprobe "$APP/Contents/Helpers/"
if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
# Sign inside out: the helper programs before the app that contains them.
codesign --force --sign - "$APP/Contents/Helpers/ffmpeg" "$APP/Contents/Helpers/ffprobe"
codesign --force --sign - "$APP"
echo "Built $APP"
