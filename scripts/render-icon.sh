#!/usr/bin/env sh
# `npm run icon` — regenerate BOTH of this app's marks from their one source.
#
#   assets/icon.png          the 1024² shelf tile clatch.json declares (docs/ICONS.md)
#   src-tauri/icons/icon.ico the Windows executable resource tauri-build embeds
#
# clock's tile is not a placeholder monogram: it is drawn to Apple's own measured
# Clock.app geometry by scripts/render-clock-icon.swift, which IS the source of truth.
# The .ico is derived from the PNG, so it goes stale the moment the PNG changes — which
# is exactly what happened to a sibling clapp, whose taskbar icon inherited an old
# render. Chaining the two here is what stops that.
#
# macOS-only (AppKit for the renderer, Pillow for the .ico). A dev task, never a build
# step: both outputs are committed.
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

PNG="$ROOT/$(manifest icon || printf 'assets/icon.png')"
ICO="$ROOT/src-tauri/icons/icon.ico"

step "render $(basename -- "$PNG")"
command -v swift >/dev/null 2>&1 || fail "swift not found — the renderer needs macOS + Xcode CLT"
( cd "$ROOT" && swift scripts/render-clock-icon.swift >&2 )
[ -f "$PNG" ] || fail "the renderer produced no $PNG"
ok "$(python3 -c "from PIL import Image; im=Image.open('$PNG'); print('%dx%d' % im.size)" 2>/dev/null || printf 'written')"

step "derive $(basename -- "$ICO")"
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 - "$PNG" "$ICO" <<'PY' >&2
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
# The layer set every clapp's icon.ico carries; 256 is what Windows shows at large sizes.
im.save(dst, sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
PY
  ok "16/32/48/64/128/256"
else
  note "Pillow not installed (pip install pillow) — icon.ico left stale"
fi
