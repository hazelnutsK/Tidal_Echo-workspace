#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/../Assets/AppIconSource.png"
OUTPUT="$SCRIPT_DIR/../TidalEcho/Assets.xcassets/AppIcon.appiconset"

test -f "$SOURCE"
mkdir -p "$OUTPUT"

for size in 40 58 60 80 87 120 180 1024; do
  sips -z "$size" "$size" "$SOURCE" --out "$OUTPUT/icon-$size.png" >/dev/null
done

echo "Prepared iOS AppIcon images from ios/Assets/AppIconSource.png"
