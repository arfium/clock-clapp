# Icon standard

> ### Reading this in clock-clapp
>
> This is the **shared house document**, copied verbatim from `template-clapp` so it can
> be read from inside this repo. Two things differ here:
>
> * Where the text says the depot is `dist/`, clock's depot is **`pkg/`** — `dist/` is
>   Vite's output, and `npm run package` assembles `pkg/`.
> * clock's tile is not a placeholder monogram: `scripts/render-clock-icon.swift` is its
>   source of truth, and **`npm run icon`** re-renders `assets/icon.png` *and* derives
>   `src-tauri/icons/icon.ico` (the Windows executable resource) from it, so the two
>   cannot drift.
>
> Fix this document in `template-clapp`; never fork it here.

The [Clapp Protocol](protocol.md#presentation-assets--icon--banner) fixes the **format**
of `assets/icon.png` — a square **PNG**, **512×512 – 1024×1024**, ≤ 1 MiB, shown as the
library tile, the 76px detail hero, and desktop shortcuts. This document fixes the
**design** so that every clapp in a shelf reads at the same size and quality. The
protocol is normative for format; this is the house style for composition.

> **Why a house style?** Icons live side by side in the Clatch library. If one fills its
> tile and another floats at 70%, the shelf looks broken. A single fill rule fixes it.

## The rules

1. **Render at 1024×1024, RGBA.** Always author at the max resolution; Clatch scales down
   cleanly. Keep an editable **source** next to the PNG (`assets/icon.svg`, or a
   `scripts/render-*-icon.swift`) so the mark can be regenerated, never hand-traced.

2. **Tiled icons are full-bleed.** The rounded tile fills the **entire** canvas — the
   fill reaches all four edges; only the rounded corners are transparent. Corner radius
   is **0.225 × side** (≈ 230px at 1024). This is the default for any app with a colored
   background (telegram, whatsapp, clock, the template itself).

3. **Transparent icons maximize the glyph.** If the app wants no tile (e.g. chess's
   pawn), drop the background to alpha and scale the mark to **~95–98% of the canvas
   height**, centered. A tall, narrow mark won't fill the width — that's fine; match the
   *height* so it carries the same visual weight as a full-bleed tile.

4. **The mark reads on light *and* dark.** The library and dock can be either. A mark on
   a saturated tile is safe. A transparent mark needs its own definition — a crisp
   outline and/or a soft shadow — so it doesn't vanish on a matching background.

5. **Use the real mark for real services.** When the app represents a real product
   (Telegram, WhatsApp), compose the **official glyph** (e.g. from
   [simple-icons](https://simpleicons.org)) onto the brand tile. Don't approximate a
   logo by hand, and **never** stand in an SF Symbol for a brand mark (see
   [In-app usage](#in-app-usage)).

**Fill target:** tiles **100% × 100%**; transparent marks **~95%+ height**. Measure it:

```sh
python3 - <<'PY'
from PIL import Image
im = Image.open("assets/icon.png").convert("RGBA"); W,H = im.size; b = im.getbbox()
print(f"{100*(b[2]-b[0])//W}% x {100*(b[3]-b[1])//H}%")   # want ~100% (tile) / ~95%+ h (glyph)
PY
```

## Producing an icon

### From an SVG (preferred for vector marks)

Keep `assets/icon.svg`, render with `rsvg-convert` (librsvg — `brew install librsvg`):

```sh
rsvg-convert -w 1024 -h 1024 assets/icon.svg -o assets/icon.png
```

A full-bleed brand tile is a `<rect>` over the whole `viewBox` plus the mark on top:

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="1024" height="1024">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="24" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#2AABEE"/><stop offset="1" stop-color="#229ED9"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="24" height="24" rx="5.4" ry="5.4" fill="url(#tile)"/> <!-- 5.4/24 = 0.225 -->
  <path transform="translate(12,12) scale(1.24) translate(-12,-12)" fill="#fff" d="…the mark…"/>
</svg>
```

For a **transparent** icon, drop the `<rect>` and set the `viewBox` tight around the
mark so it fills the frame (chess uses `viewBox="5.4 7 34.2 34.2"` to hit ~98% height).

### Programmatically (Swift, for drawn icons)

Icons that aren't a single path (clock's dial, the template's monogram) are drawn by a
`scripts/render-*-icon.swift` into an `NSBitmapImageRep` and written to `assets/icon.png`.
The full-bleed rule applies the same way — the plate is the **whole** canvas:

```swift
let plate = NSRect(x: 0, y: 0, width: 1024, height: 1024)          // full-bleed
let path  = NSBezierPath(roundedRect: plate, xRadius: 230, yRadius: 230)   // 0.225 × 1024
```

> **macOS-Dock aside.** Apple's own Dock icons inset to ~0.80 for bounce headroom. The
> Clatch **library grid** wants edge-to-edge, so clapps fill the canvas. Don't copy the
> 0.80 inset — it reads as undersized next to full-bleed neighbours.

## In-app usage

If the GUI shows the app's mark (e.g. a window header), show the **real icon**, not an
approximation. Bundle it as a SwiftPM resource and load it via `Bundle.module`:

```swift
// package the PNG so Bundle.module can find it
cp assets/icon.png native/Sources/<app>/Resources/appicon.png     // Package.swift: resources: [.process("Resources")]

// in the view
if let url = Bundle.module.url(forResource: "appicon", withExtension: "png"),
   let img = NSImage(contentsOf: url) { Image(nsImage: img).resizable().frame(width: 44, height: 44) }
```

`scripts/package.sh` already copies the SwiftPM `*.bundle` into `dist/bin/`, so the
bundled icon travels into the installed app. **Do not** use an SF Symbol (`paperplane.fill`,
`phone.fill`) as a stand-in for a brand mark — it is close enough to look like a bug.

## dist/ discipline (the staleness trap)

`dist/assets/icon.png` is a **copy** that `scripts/package.sh` makes from the top-level
`assets/icon.png`. It does **not** update itself. After you change the icon:

```sh
npm run package        # refresh dist/ from the new assets/icon.png
npm run pack           # (optional) re-pack the .clapp
```

`dist/` and `*.clapp` are **build artifacts** — gitignored in every clapp; the committed
`assets/icon.png` is the single source of truth. If the shelf shows an old icon, the
cause is almost always a stale `dist/` — repackage.

## Checklist

- [ ] `assets/icon.png` is 1024×1024 RGBA PNG, ≤ 1 MiB
- [ ] an editable source exists (`assets/icon.svg` or a `render-*-icon.swift`)
- [ ] tile fills the canvas (100%) at radius `0.225 × side`; **or** transparent mark ≥ 95% height
- [ ] reads on light and dark
- [ ] real service → official mark, not an SF Symbol
- [ ] repackaged after the change (`dist/` icon matches the top-level one)
