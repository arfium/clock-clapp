#!/usr/bin/env sh
# A macOS .app that runs `clatch run com.arfium.clock` — a double-clickable launcher
# that goes THROUGH Clatch. usage: scripts/macos-shortcut.sh /abs/path/to/clatch [Clock.app]
set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

CLATCH_BIN="${1:-$(find_clatch || true)}"
APP="${2:-$ROOT/build/Clock.app}"
ID="$(manifest id)"
VERSION="$(manifest version)"

if [ -z "$CLATCH_BIN" ] || [ ! -x "$CLATCH_BIN" ]; then
  printf '%s\n' "usage: scripts/macos-shortcut.sh /absolute/path/to/clatch [Clock.app]" >&2
  exit 1
fi

CONTENTS="$APP/Contents"; MACOS="$CONTENTS/MacOS"; RESOURCES="$CONTENTS/Resources"
ICONSET="$ROOT/build/clock.iconset"

rm -rf "$APP" "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"

cat >"$MACOS/clock-launcher" <<EOF
#!/bin/sh
exec "$CLATCH_BIN" run $ID
EOF
chmod +x "$MACOS/clock-launcher"

cat >"$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Clock</string>
  <key>CFBundleExecutable</key><string>clock-launcher</string>
  <key>CFBundleIconFile</key><string>clock</string>
  <key>CFBundleIdentifier</key><string>com.arfium.clock.shortcut</string>
  <key>CFBundleName</key><string>Clock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF

sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/" "$CONTENTS/Info.plist"

if [ -f "$ROOT/assets/icon.png" ]; then
  for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" \
              "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" \
              "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" \
              "1024 icon_512x512@2x.png"; do
    set -- $spec
    sips -s format png -z "$1" "$1" "$ROOT/assets/icon.png" --out "$ICONSET/$2" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RESOURCES/clock.icns"
fi
rm -rf "$ICONSET"

printf '%s\n' "$APP"
