#!/bin/bash
# ============================================================================
# OpenSurfer — one-shot standalone browser build.
#
# Produces a distributable OpenSurfer.app (and optionally a .dmg) by building
# Chromium from source with the OpenSurfer patches, branding, and the compiled
# sidebar extension applied.
#
# This automates every step in chromium/contributing.md so it can run
# unattended. It is idempotent and resumable: each phase detects whether it has
# already completed and skips ahead, so re-running after an interruption picks
# up where it left off.
#
# Usage:
#   bash chromium/scripts/build_app.sh              # full build → OpenSurfer.app
#   bash chromium/scripts/build_app.sh --dmg        # also package a .dmg
#   bash chromium/scripts/build_app.sh --extension-only
#   SKIP_FETCH=1 bash chromium/scripts/build_app.sh # reuse existing chromium/src
#
# Expect the first run to take several hours and ~100GB of disk: the Chromium
# fetch is ~30GB and the compile pins every core.
# ============================================================================

set -euo pipefail

# ---- pinned Chromium version (from chromium/contributing.md) ----------------
CHROMIUM_TAG="146.0.7647.0"
CHROMIUM_REVISION="f2722c85cc7f44f035bfc91b40406883e8f3b07d"

# ---- output build directory --------------------------------------------------
OUT_DIR="out/fast"
APP_NAME="OpenSurfer"

# ---- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROMIUM_META_DIR="$(dirname "$SCRIPT_DIR")"          # <repo>/chromium
REPO_ROOT="$(dirname "$CHROMIUM_META_DIR")"           # <repo>
WORKSPACE_ROOT="$(dirname "$REPO_ROOT")"              # parent of the repo
CHROMIUM_ROOT="$WORKSPACE_ROOT/chromium"             # sibling checkout dir
CHROMIUM_SRC="$CHROMIUM_ROOT/src"
DEPOT_TOOLS_DIR="$WORKSPACE_ROOT/depot_tools"

# ---- pretty logging ----------------------------------------------------------
c_blue='\033[0;34m'; c_green='\033[0;32m'; c_yellow='\033[1;33m'
c_red='\033[0;31m'; c_cyan='\033[0;36m'; c_reset='\033[0m'
phase() { echo -e "\n${c_blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_reset}"; \
          echo -e "${c_cyan}▶ $*${c_reset}"; \
          echo -e "${c_blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_reset}"; }
ok()   { echo -e "${c_green}✔ $*${c_reset}"; }
warn() { echo -e "${c_yellow}! $*${c_reset}"; }
die()  { echo -e "${c_red}✘ $*${c_reset}"; exit 1; }

# ---- args --------------------------------------------------------------------
MAKE_DMG=0
EXTENSION_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dmg) MAKE_DMG=1 ;;
    --extension-only) EXTENSION_ONLY=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

# ---- locate pnpm (this machine keeps it outside PATH) ------------------------
find_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then echo "pnpm"; return; fi
  for p in \
    "$HOME/.local/node/lib/node_modules/pnpm/pnpm" \
    "$HOME/Library/pnpm/pnpm" \
    "/usr/local/lib/node_modules/pnpm/bin/pnpm.cjs"; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  die "pnpm not found — install it or add it to PATH"
}
PNPM="$(find_pnpm)"

# ============================================================================
# Phase 0 — host prerequisites
# ============================================================================
phase "Phase 0/6 — Prerequisites"

command -v git >/dev/null || die "git is required"
command -v python3 >/dev/null || die "python3 is required"
if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode Command Line Tools missing — run: xcode-select --install"
fi
ok "git, python3, Xcode CLT present"

# depot_tools (full clone — a shallow clone breaks self-update)
if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
  warn "depot_tools not found — cloning into $DEPOT_TOOLS_DIR"
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
else
  ok "depot_tools present"
fi
export PATH="$DEPOT_TOOLS_DIR:$PATH"
export DEPOT_TOOLS_UPDATE=1

# Bootstrap: fetch/gclient need depot_tools' bundled toolchain on disk before
# first use, otherwise fetch dies with "python3_bin_reldir.txt not found".
if [ ! -f "$DEPOT_TOOLS_DIR/python3_bin_reldir.txt" ]; then
  warn "bootstrapping depot_tools (first run) …"
  gclient --version >/dev/null 2>&1 || true
fi
[ -f "$DEPOT_TOOLS_DIR/python3_bin_reldir.txt" ] \
  && ok "depot_tools bootstrapped" \
  || warn "depot_tools bootstrap incomplete — fetch will retry it"

# ============================================================================
# Phase 1 — build the sidebar extension (carries the Buzz theme)
# ============================================================================
phase "Phase 1/6 — Build extension"
(
  cd "$REPO_ROOT"
  "$PNPM" install --frozen-lockfile 2>/dev/null || "$PNPM" install
  cd chromium-extension
  "$PNPM" build
)
[ -f "$REPO_ROOT/chromium-extension/dist/js/sidebar.js" ] \
  || die "extension build produced no dist/js/sidebar.js"
ok "extension built → chromium-extension/dist"

if [ "$EXTENSION_ONLY" = "1" ]; then
  ok "extension-only build complete"; exit 0
fi

# ============================================================================
# Phase 2 — fetch Chromium source at the pinned version
# ============================================================================
phase "Phase 2/6 — Chromium source ($CHROMIUM_TAG)"
mkdir -p "$CHROMIUM_ROOT"

if [ "${SKIP_FETCH:-0}" = "1" ] && [ -d "$CHROMIUM_SRC" ]; then
  warn "SKIP_FETCH set — reusing existing $CHROMIUM_SRC"
elif [ ! -d "$CHROMIUM_SRC" ]; then
  warn "fetching Chromium — this downloads ~30GB and can take 1–3 hours"
  ( cd "$CHROMIUM_ROOT" && fetch --nohooks chromium )
else
  ok "Chromium checkout already present"
fi

phase "Phase 2b — Sync to pinned revision"
( cd "$CHROMIUM_SRC" && git fetch --tags origin "$CHROMIUM_TAG" 2>/dev/null || true )
( cd "$CHROMIUM_SRC" && git checkout "$CHROMIUM_REVISION" 2>/dev/null \
    || git checkout "$CHROMIUM_TAG" )
( cd "$CHROMIUM_ROOT" && gclient sync --with_branch_heads --with_tags \
    -r "src@${CHROMIUM_REVISION}" )
ok "Chromium synced at $CHROMIUM_REVISION"

# ============================================================================
# Phase 3 — apply OpenSurfer patches, branding, and the extension
# ============================================================================
phase "Phase 3/6 — Apply patches + branding + extension"
bash "$SCRIPT_DIR/setup_openbrowser.sh"
ok "patches, branding, and extension applied to Chromium tree"

# ============================================================================
# Phase 4 — configure the release build
# ============================================================================
phase "Phase 4/6 — Configure ($OUT_DIR)"
GN_ARGS=$(cat <<'GN'
is_debug = false
is_component_build = false
symbol_level = 0
blink_symbol_level = 0
is_official_build = true
enable_nacl = false
proprietary_codecs = true
ffmpeg_branding = "Chrome"
use_remoteexec = false
dcheck_always_on = false
GN
)
# Apple Silicon vs Intel target CPU
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" = "arm64" ]; then
  GN_ARGS="$GN_ARGS"$'\n''target_cpu = "arm64"'
else
  GN_ARGS="$GN_ARGS"$'\n''target_cpu = "x64"'
fi
( cd "$CHROMIUM_SRC" && gn gen "$OUT_DIR" --args="$GN_ARGS" )
ok "GN configured"

# ============================================================================
# Phase 5 — compile (the long one)
# ============================================================================
phase "Phase 5/6 — Compile chrome (hours; pins all cores)"
( cd "$CHROMIUM_SRC" && autoninja -C "$OUT_DIR" chrome )
APP_PATH="$CHROMIUM_SRC/$OUT_DIR/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  # Chromium may output as "Chromium.app" if branding didn't rename it.
  ALT_APP="$(find "$CHROMIUM_SRC/$OUT_DIR" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$ALT_APP" ] && APP_PATH="$ALT_APP"
fi
[ -d "$APP_PATH" ] || die "build finished but no .app found in $OUT_DIR"
ok "built: $APP_PATH"

# ============================================================================
# Phase 6 — package
# ============================================================================
phase "Phase 6/6 — Package"
DIST_DIR="$REPO_ROOT/dist-app"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/$(basename "$APP_PATH")"
cp -R "$APP_PATH" "$DIST_DIR/"
ok "app copied → $DIST_DIR/$(basename "$APP_PATH")"

if [ "$MAKE_DMG" = "1" ]; then
  DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
  rm -f "$DMG_PATH"
  warn "creating .dmg (unsigned — see note below)"
  hdiutil create -volname "$APP_NAME" -srcfolder "$DIST_DIR/$(basename "$APP_PATH")" \
    -ov -format UDZO "$DMG_PATH"
  ok "dmg created → $DMG_PATH"
  echo ""
  warn "This .dmg is UNSIGNED. To distribute it without Gatekeeper warnings you"
  warn "must code-sign with a Developer ID cert and notarize:"
  echo "    codesign --deep --force --options runtime \\"
  echo "      --sign \"Developer ID Application: <YOUR NAME> (<TEAMID>)\" \\"
  echo "      \"$DIST_DIR/$(basename "$APP_PATH")\""
  echo "    xcrun notarytool submit \"$DMG_PATH\" --keychain-profile <profile> --wait"
  echo "    xcrun stapler staple \"$DMG_PATH\""
fi

phase "Done"
ok "OpenSurfer app is in $DIST_DIR"
echo -e "${c_cyan}Run it:${c_reset} open \"$DIST_DIR/$(basename "$APP_PATH")\""
