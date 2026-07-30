#!/usr/bin/env sh
# Shared helpers for this clapp's scripts. SOURCED, never executed:
#
#   . "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
#
# This file is BYTE-IDENTICAL in every clapp (template, chess, clock, telegram,
# whatsapp). Fix it in one repo, copy it to the others — never fork it.
#
# Identity is read from clatch.json rather than being sed-substituted into the
# scripts: the manifest is the single source of truth for the app id and the CLI
# name, so a fork rewrites ONE file and every script here follows automatically.

# The repo root. Computed from $0 — the script that sourced us, always scripts/*.sh.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# ── pretty output ───────────────────────────────────────────────────────────────
# Everything here goes to STDERR. stdout is reserved: `package.sh` prints exactly
# one line there, the depot path, so `clatch validate "$(npm run -s package)"` is a
# legal thing to write.
step() { printf '\n▸ %s\n' "$1" >&2; }
ok()   { printf '  ok%s\n' "${1:+ — $1}" >&2; }
note() { printf '  (%s)\n' "$1" >&2; }
fail() { printf '\n✗ FAIL — %s\n' "$1" >&2; exit 1; }

# ── the manifest is the source of truth ─────────────────────────────────────────
# Print one dotted path out of clatch.json (`manifest connector.cli`). node is used
# rather than jq or python3 because every clapp already needs node for its frontend,
# on every OS including Windows — jq is not installed by default anywhere and
# python3 is absent on a stock Windows box.
manifest() {
  node -e '
    const [path, file] = process.argv.slice(1);
    let v = JSON.parse(require("fs").readFileSync(file, "utf8"));
    for (const k of path.split(".")) v = (v == null ? v : v[k]);
    if (v === undefined || v === null) process.exit(1);
    process.stdout.write(String(v));
  ' "$1" "$ROOT/clatch.json"
}

# Print the depot-relative path a manifest declares for one of the three things that
# must physically exist in the depot — `cliBin`, `launch` or `icon` — resolved for an
# OS. Empty output means "not declared for this OS", which is not an error.
manifest_path() { # <manifest> <cliBin|launch|icon> <os>
  node -e '
    const [file, kind, os] = process.argv.slice(1);
    const m = JSON.parse(require("fs").readFileSync(file, "utf8"));
    const per = (v) => (v && typeof v === "object" ? v[os] : v);
    const out =
      kind === "cliBin" ? (m.connector && (m.connector.cliBin || "bin/" + m.connector.cli))
    : kind === "launch" ? per(m.launch)
    :                     m.icon;
    process.stdout.write(out || "");
  ' "$1" "$2" "$3"
}

# Copy clatch.json into the depot, with connector.cliBin forced to <cliBin>.
#
# `connector.cliBin` is a single string — protocol.md §1 gives it no per-OS form the
# way `launch` has — so the repo manifest can only carry one spelling, and it carries
# the POSIX one (`bin/chess`). Windows will not execute an extensionless image, and
# Clatch's check_files() hard-errors ("declared CLI binary not found in the package")
# on both `clatch validate` and `clatch install`, so a Windows depot built from the
# repo manifest verbatim cannot be installed at all. A `.clapp` is already per-OS-arch
# (<id>-<os>-<arch>.clapp), so rewriting the DEPOT copy is the honest fix. The repo
# copy stays POSIX — do not "fix" it there.
install_manifest() { # <src> <dst> <cliBin>
  node -e '
    const fs = require("fs");
    const [src, dst, cliBin] = process.argv.slice(1);
    const m = JSON.parse(fs.readFileSync(src, "utf8"));
    if (m.connector) m.connector.cliBin = cliBin;
    fs.writeFileSync(dst, JSON.stringify(m, null, 2) + "\n");
  ' "$1" "$2" "$3"
}

# ── the host ────────────────────────────────────────────────────────────────────
# uname is the portable answer on macOS and Linux AND under Git Bash / MSYS2 /
# Cygwin on Windows, where it reports MINGW64_NT-… / MSYS_NT-… / CYGWIN_NT-….
host_os() {
  case "$(uname -s)" in
    Darwin)               printf 'macos' ;;
    Linux)                printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *)                    printf 'unknown' ;;
  esac
}

# The executable suffix for the host: Windows will not run an extensionless image.
exe_suffix() { if [ "$(host_os)" = windows ]; then printf '.exe'; fi; }

# A Windows path (C:\x\y) turned into something this shell can open. Only Git Bash /
# Cygwin ever need it, and only they ship cygpath.
unixpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

# ── the clatch CLI ──────────────────────────────────────────────────────────────
# $CLATCH_BIN wins, then PATH, then the sibling checkout every dev here has
# (clapps/<app>-clapp/../../clatch). Prints the path; returns 1 when there is none,
# so callers can decide whether that is a skip or a failure.
find_clatch() {
  if [ -n "${CLATCH_BIN:-}" ] && [ -x "$CLATCH_BIN" ]; then printf '%s' "$CLATCH_BIN"; return 0; fi
  if command -v clatch >/dev/null 2>&1; then command -v clatch; return 0; fi
  for c in "$ROOT/../../clatch/target/release/clatch$(exe_suffix)"; do
    if [ -x "$c" ]; then (CDPATH= cd -- "$(dirname -- "$c")" && printf '%s/%s' "$(pwd)" "$(basename -- "$c")"); return 0; fi
  done
  return 1
}

# ── the Tauri build ─────────────────────────────────────────────────────────────
# THE ONE CORRECT WAY TO BUILD A TAURI CLAPP. Read this before "simplifying" it to
# `cargo build --release`:
#
#   Tauri's `custom-protocol` cargo feature is turned on by the Tauri CLI, not by
#   cargo. Build with plain cargo and the release binary is still a DEV binary: it
#   points the webview at `build.devUrl` (http://localhost:142x) instead of serving
#   the frontend embedded in the executable. The packaged app then comes up as a
#   white window — or, if a dev server happens to be running on that port, as the
#   WRONG app's UI. That mistake has already cost this project a debugging session;
#   the assertion in package.sh (the hashed bundle name must appear inside the
#   binary) is the guard that makes it impossible to ship again.
#
# `--no-bundle` skips the .app/.dmg/.msi/.deb step: a clapp depot is bin/ + assets/
# + clatch.json, not an OS installer. (bundle.active is already false in
# tauri.conf.json; passing the flag makes the intent explicit and survives that
# being flipped for some other purpose.)
#
# CLAPP_FRONTEND_ONLY is the re-entrancy guard for `npm run build` — see build.sh.
tauri_build() {
  ( cd "$ROOT" && CLAPP_FRONTEND_ONLY=1 npm run --silent tauri -- build --no-bundle >&2 )
}

# The guard for the trap above, run on the binary that is about to be packaged.
#
# Vite writes hashed bundle names (dist-web/assets/index-yG4_5Aww.js) and Tauri's
# custom-protocol build embeds the frontend under those exact names, so the string is
# findable inside the executable. A binary built WITHOUT custom-protocol has no
# embedded frontend at all — the check fails, loudly, here, instead of shipping an
# app that opens a white window on someone else's machine.
assert_frontend_embedded() { # <binary>
  # Where the frontend lands is tauri.conf.json's call (build.frontendDist), not ours —
  # read it rather than hardcoding, so moving dist/ → dist-web/ cannot silently turn
  # this guard into a no-op.
  web="$(cd "$ROOT/src-tauri" && node -e '
    const c = JSON.parse(require("fs").readFileSync("tauri.conf.json", "utf8"));
    process.stdout.write(require("path").resolve((c.build && c.build.frontendDist) || "../dist"));
  ')"
  bundle="$(ls "$web/assets/"*.js 2>/dev/null | head -1)"
  [ -n "$bundle" ] || fail "no bundle in $web/assets — the frontend never built"
  bundle="$(basename -- "$bundle")"
  LC_ALL=C grep -aq -- "$bundle" "$1" || fail "$(basename -- "$1") does not embed the frontend ($bundle).
      That is what a binary built WITHOUT Tauri's custom-protocol feature looks like —
      a plain \`cargo build --release\`. It would point the webview at devUrl and open
      a white window (or a stale dev page). Build with scripts/package.sh."
}
