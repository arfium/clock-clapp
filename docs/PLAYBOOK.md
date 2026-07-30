# The clapp playbook

> ### Reading this in clock-clapp
>
> This is the **shared house document**, copied verbatim from `template-clapp` so it can
> be read from inside this repo. Two things differ here:
>
> * Where the text says the depot is `dist/`, clock's depot is **`pkg/`** — `dist/` is
>   Vite's output, and `npm run package` assembles `pkg/`.
> * Where it says `swift build`, use **`npm run build`**. clock is Rust + Tauri v2, and
>   the binary must be built through the Tauri CLI: a bare `cargo build --release` ships
>   with no embedded frontend and opens a white window.
>
> Fix this document in `template-clapp`; never fork it here.

Patterns and hard-won lessons from shipping real clapps on this template — **chess**
(a full game), **clock** (a scheduler), **telegram** and **whatsapp** (agent messaging
bridges). The template teaches the *transport*; this teaches the *judgement* around it.
Each rule below cost a rewrite to learn.

---

## 1. A `.clapp` ships real files only — no symlinks

The `.clapp` depot is a zip rooted at `clatch.json`, and **Clatch's packer drops
symlinks** ("a depot ships real files only"). Anything that relies on a symlink is broken
the moment it's installed.

- **Never ship `node_modules/`.** npm's `node_modules/.bin/*` are symlinks; they become
  dead files on unpack, and a `require('./')` off one of them throws at launch. This is
  the single most expensive mistake we made.
- **Bundle to one file, vendor runtimes as real binaries.** A Node integration becomes
  *one* esbuild bundle (`whatsapp-sidecar.js`, 7 MB) plus a *copied* `node` binary
  (`vendor/node`, a real Mach-O). No symlinks, and the depot went from **312 MB → 35 MB**.
- **Keep the depot small.** A pure-Swift clapp is ~300 KB. Adding a runtime is a real
  cost — pay it only when a library forces you to (§2).

> **The Electron cautionary tale.** The first telegram/whatsapp builds were Electron.
> They failed to register under Clatch ("did not register within 10s") because
> `node_modules/.bin/electron` was a dropped symlink, and each depot was ~700 MB. Both
> were rebuilt native. If a design needs a symlinked runtime, the design is wrong.

## 2. Native first; a sidecar only when a library forces it

Decide by the **integration**, not the language you like:

- **The service speaks HTTPS/JSON → do it in pure Swift.** The Telegram **Bot API** is
  just HTTPS, so `telegram` is `URLSession` and **zero** dependencies — `getUpdates`
  long-poll, `sendMessage`, `getMe`. No runtime to vendor, a 260 KB `.clapp`.
- **The integration needs a JS-only library → bundle a sidecar.** WhatsApp Web is the
  Signal protocol over a websocket (Baileys); it **cannot** be reimplemented in Swift. So
  `whatsapp` is a native Swift GUI **plus** a bundled Baileys Node sidecar the app drives.

**The sidecar contract** (see `whatsapp-clapp`), if you must:

- One **esbuild bundle** (`--bundle --platform=node`) — a single file, per §1.
- **Vendor `node`** as a real binary; resolve it and the bundle **relative to the
  executable** (`Bundle.main.executableURL` → `vendor/node`, `sidecar/…`), with env
  overrides (`WHATSAPP_NODE`, `WHATSAPP_SIDECAR`) for dev.
- Talk **newline-JSON over stdio**. **Silence the library's own logging** (Baileys →
  `pino({level:'silent'})`) so stdout carries only your protocol.
- **Die with the parent:** exit on stdin EOF. The Swift side closes stdin on terminate.
- Writable state (auth keys) goes to `~/.<app>/`, **not** the read-only install dir.

## 3. Preview the GUI without a display

A headless/CI/agent box has no window server — a screenshot is black. Render the SwiftUI
**offscreen** instead, with a dev-only `render` subcommand:

```swift
case "render":                                   // telegram render out.png [setup|linked]
    let renderer = ImageRenderer(content: ContentView(state: mockState).frame(width: 460, height: 560))
    renderer.scale = 2
    // renderer.nsImage → NSBitmapImageRep → write PNG
```

Give `AppState` an `applyPreview(_:)` that fills mock state for each screen, so you can
render *every* state (empty, linked, error, QR) into a PNG and actually **look** at your
design before you ship it. `ImageRenderer` needs no display. (Caveat: it renders
`SecureField` as a yellow bar — that's an offscreen artifact, fine in the live app.)

## 4. Match the app's brand — don't leave the template's skin on

The template ships the **Clatch Phosphor** theme (dark, volt accent). That's right for a
Clatch-native tool, **wrong** for an app that mimics a real product. For branded clapps:

- Rewrite `Theme.swift` with the brand's tokens (telegram → light + `#3390EC`; whatsapp →
  `#F0F2F5` chrome + `#00A884`). Use the **system face** for native-feeling brands.
- Capture the design language as a **`docs/DESIGN.md`** in the token format of
  [voltagent/awesome-design-md](https://github.com/voltagent/awesome-design-md) — colors,
  typography, radii, components. It's the source of truth for the theme and lets any agent
  rebuild the UI. (That repo lacked Telegram/WhatsApp; we authored them from the real
  systems — do the same for a brand it doesn't cover.)
- Follow the [icon standard](ICONS.md) so the mark matches the skin.

## 5. Keep source and manifest in lockstep

`clatch validate` checks the manifest; **nothing** checks that your Swift matches it. The
[three that must agree](TEMPLATE.md) — `id`, `cli`, and the `signals` (id **and** type) —
are yours to keep aligned. `npm run verify` is the guard: it builds, packages, validates,
and round-trips the socket in one command. Run it before every commit.

## 6. `dist/` and `*.clapp` are derived — never commit them

They're **build outputs**: `scripts/package.sh` assembles `dist/`, `clatch pack` (or the
release workflow's `zip`) makes the `.clapp`. Gitignore **both** in every clapp
(`dist/`, `*.clapp`, `*.clapp.sha256`) so they never drift in the repo. The committed
`assets/icon.png` (and source) is the truth; `dist/` is a copy you refresh. The official,
downloadable `.clapp` is what `.github/workflows/release.yml` builds on a `v*` tag — see
[Distribution](#distribution).

## 7. Distribution: a tag, not a folder

End users install a **release or a file**, never your source tree:

```sh
clatch install github:<owner>/<repo>            # latest release
clatch install github:<owner>/<repo>@v0.1.0     # a tag
clatch install ./<id>-macos-arm64.clapp         # a downloaded depot
```

Push a `v*` tag → `release.yml` builds `<id>-macos-arm64.clapp` (+ `.sha256`) and
publishes it. For a clapp with a sidecar, the workflow also needs the toolchain that
`package.sh` uses (e.g. `actions/setup-node`) — the vendored `node` is resolved from the
runner's `node`. `zip -r` preserves the exec bits Clatch restores on install.

## Verify it end to end, against real Clatch

`npm run verify` proves the surfaces talk; before you call a clapp done, prove it
**installs and runs under Clatch** — the exact step Electron failed:

```sh
clatch validate dist            # valid: <id> …
clatch pack dist                # → <id>-macos-arm64.clapp
clatch install ./<id>-*.clapp   # unpack into the depot
clatch run <id>                 # must reach a live/registered state
<cli> status                    # CLI round-trips against the installed app
```

For a sidecar clapp, confirm the app spawns the **depot's own** `vendor/node`
(`pgrep -fl <sidecar>`) and that `clatch stop` cleans it up.

---

## Field notes (smaller traps)

- **Baileys `405 Connection Failure`** on connect is usually a stale WhatsApp-Web version
  **or** IP rate-limiting from hammering reconnects. Fix: `fetchLatestBaileysVersion()`,
  and don't open dozens of connections in a testing loop — back off.
- **BSD `sed` has no `\b`** word boundaries (macOS). Scripts that must run on stock macOS
  can't rely on GNU-only regex.
- **Stale SwiftPM build cache.** Copying a repo (fork-by-copy) can drag a `.build/` whose
  module-cache path no longer matches → "PCH was compiled with module cache path …". Fix:
  `rm -rf native/.build` and rebuild.
- **The shell cwd resets between tool calls** in an agent harness; use absolute paths or
  `( cd "$d" && … )` subshells, and don't nest a second `cd "$d"` inside one.
- **A declared `icon` must exist on disk** or `validate`/`install` fails.
- **The Dock shows the generic terminal icon** for a bare Swift executable (no `.app`
  bundle). Fix: bundle the mark as `Resources/appicon.png` and set
  `NSApp.applicationIconImage = NSImage(contentsOf: Bundle.module.url(forResource: "appicon", withExtension: "png")!)`
  in `applicationDidFinishLaunching`. (The clock instead draws a *live* icon via
  `NSApp.dockTile.contentView` — same idea, fancier.)
