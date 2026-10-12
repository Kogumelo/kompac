#!/bin/zsh
# Generates icon/Kompac.icns from icon/kompac.svg (and icon/kompac-16.svg for the 16 px image).
# Run it only when the drawing changes: the .icns is versioned and build.sh just copies it.
set -e
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

# the converter uses macOS's own SVG support (NSImage); no need for rsvg-convert or ImageMagick
swiftc -O svg2png.swift -o "$TMP/svg2png"

mkdir "$TMP/Kompac.iconset"
for n in 16 32 128 256 512; do
  src=kompac.svg
  [ $n = 16 ] && src=kompac-16.svg   # 16 px has its own pixel-grid drawing; the zipper teeth blur away at that size
  "$TMP/svg2png" $src "$TMP/Kompac.iconset/icon_${n}x${n}.png" $n
  "$TMP/svg2png" kompac.svg "$TMP/Kompac.iconset/icon_${n}x${n}@2x.png" $((n * 2))
done
iconutil -c icns "$TMP/Kompac.iconset" -o Kompac.icns

echo "OK: $PWD/Kompac.icns"
