#!/usr/bin/env sh
# Assemble dist/{clatch.json, bin/clock (compiled binary), assets/icon.png}.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DIST="$ROOT/dist"

swift build -c release --package-path "$ROOT/native" >/dev/null

rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/assets"
cp "$ROOT/native/.build/release/clock" "$DIST/bin/clock"
find "$ROOT/native/.build" -path "*/release/*.bundle" -name "*clock*.bundle" -prune -exec cp -R {} "$DIST/bin/" \; -quit 2>/dev/null || true
cp "$ROOT/clatch.json" "$DIST/clatch.json"
cp "$ROOT/assets/icon.png" "$DIST/assets/icon.png"
[ -f "$ROOT/THIRD_PARTY_NOTICES.md" ] && cp "$ROOT/THIRD_PARTY_NOTICES.md" "$DIST/THIRD_PARTY_NOTICES.md"
chmod +x "$DIST/bin/clock"

printf '%s\n' "$DIST"
