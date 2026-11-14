#!/bin/sh
# Downloads the pinned static arm64 ffmpeg and ffprobe into vendor/ffmpeg, verifying their checksums.
# They are separate GPL v3 programs that ConvertZ launches; they are not part of this repository.
set -eu
cd "$(dirname "$0")/.."

BASE="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2"
FFMPEG_SHA="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"
FFPROBE_SHA="fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6"

DIR=vendor/ffmpeg
STAMP="$DIR/.version"
if [ -x "$DIR/ffmpeg" ] && [ -x "$DIR/ffprobe" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$BASE" ]; then
    exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR"
fetch() {
    curl -fsSL --retry 3 -o "$DIR/$1.zip" "$BASE/$1.zip"
    actual=$(shasum -a 256 "$DIR/$1.zip" | awk '{print $1}')
    if [ "$actual" != "$2" ]; then
        echo "Checksum mismatch for $1.zip: got $actual" >&2
        exit 1
    fi
    unzip -q -o "$DIR/$1.zip" -d "$DIR"
    rm "$DIR/$1.zip"
    chmod +x "$DIR/$1"
}
fetch ffmpeg "$FFMPEG_SHA"
fetch ffprobe "$FFPROBE_SHA"
echo "$BASE" > "$STAMP"
echo "Fetched ffmpeg into $DIR"
