#!/usr/bin/env sh
# Wrap the release binary in a double-clickable .app for dev (CLATCH_STANDALONE=1,
# does NOT go through Clatch). Product launches go through `clatch run com.arfium.clock`.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/ClockDev.app}"
CONTENTS="$APP/Contents"; MACOS="$CONTENTS/MacOS"; RESOURCES="$CONTENTS/Resources"
ICONSET="$ROOT/dist/clock-dev.iconset"

swift build -c release --package-path "$ROOT/native" >/dev/null

rm -rf "$APP" "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"
cp "$ROOT/native/.build/release/clock" "$MACOS/clock-bin"
cat >"$MACOS/clock" <<'EOF'
#!/bin/sh
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLATCH_STANDALONE=1 exec "$DIR/clock-bin" app
EOF
chmod +x "$MACOS/clock" "$MACOS/clock-bin"

cat >"$CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Clock Dev</string>
  <key>CFBundleExecutable</key><string>clock</string>
  <key>CFBundleIconFile</key><string>clock</string>
  <key>CFBundleIdentifier</key><string>com.arfium.clock.dev</string>
  <key>CFBundleName</key><string>Clock Dev</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF

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
