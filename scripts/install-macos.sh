#!/bin/bash
# Zennox Music Player installer for macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/Anbarasu-A-N/zennox-music-player/main/scripts/install-macos.sh | bash
# Note: REPO is a default; change it to the real repository before the first release.

set -euo pipefail

main() {  # wrapped so a partially downloaded script never runs half its steps

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
REPO="${ZENNOX_REPO:-Anbarasu-A-N/zennox-music-player}"
APP_NAME="Zennox Music Player"
ASSET="Zennox-Music-Player-macOS.zip"
DEST="/Applications/${APP_NAME}.app"
MIN_MAJOR=14

ok()   { echo -e "${GREEN}✓${NC} $*"; }
step() { echo -e "${BLUE}→${NC} $*"; }
fail() { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

echo -e "\n${BOLD}  ${APP_NAME} Installer${NC}\n  ─────────────────────────────────────\n"

[ "$(uname -s)" = "Darwin" ] || fail "This installer is for macOS."
MACOS_VERSION=$(sw_vers -productVersion)
[ "${MACOS_VERSION%%.*}" -ge "$MIN_MAJOR" ] || fail "Requires macOS ${MIN_MAJOR}.0 or later (you have $MACOS_VERSION)."
ok "macOS $MACOS_VERSION ($(uname -m))"

step "Fetching latest release..."
LATEST=$(curl -fsSL --proto '=https' --tlsv1.2 "https://api.github.com/repos/${REPO}/releases/latest") \
  || fail "Could not reach GitHub. Check https://github.com/${REPO}/releases"
VERSION=$(printf '%s' "$LATEST" | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
ZIP_URL=$(printf '%s' "$LATEST" | grep '"browser_download_url"' | grep -F "/${ASSET}\"" | sed -E 's/.*"([^"]+)".*/\1/' | head -1)
SUM_URL=$(printf '%s' "$LATEST" | grep '"browser_download_url"' | grep -F '/SHA256SUMS"' | sed -E 's/.*"([^"]+)".*/\1/' | head -1)
[ -n "$ZIP_URL" ] || fail "No ${ASSET} in release ${VERSION:-?}."
[ -n "$SUM_URL" ] || fail "Release ${VERSION} has no SHA256SUMS; refusing to install an unverified download."
ok "Found ${APP_NAME} ${VERSION}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

step "Downloading..."
curl -fL --proto '=https' --tlsv1.2 --progress-bar "$ZIP_URL" -o "$TMP_DIR/$ASSET"
curl -fsSL --proto '=https' --tlsv1.2 "$SUM_URL" -o "$TMP_DIR/SHA256SUMS"

step "Verifying checksum..."
EXPECTED=$(grep -F " ${ASSET}" "$TMP_DIR/SHA256SUMS" | awk '{print $1}' | head -1)
ACTUAL=$(shasum -a 256 "$TMP_DIR/$ASSET" | awk '{print $1}')
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || fail "Checksum mismatch; download discarded."
ok "Checksum verified"

step "Extracting..."
ditto -x -k "$TMP_DIR/$ASSET" "$TMP_DIR/x"
APP_PATH="$TMP_DIR/x/${APP_NAME}.app"
[ -d "$APP_PATH" ] || fail "Archive does not contain ${APP_NAME}.app"
codesign --verify --deep --strict "$APP_PATH" 2>/dev/null || fail "App signature is invalid or damaged."
ok "Extracted and signature intact (ad-hoc)"

if pgrep -xq "$APP_NAME"; then
  step "Quitting running ${APP_NAME}..."
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  sleep 2
fi

if [ -d "$DEST" ]; then
  step "Replacing previous version..."
  rm -rf -- "$DEST"
fi
step "Installing to /Applications..."
ditto "$APP_PATH" "$DEST"

# Downloads via curl normally carry no quarantine flag; remove only that flag if present.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
ok "Installed to $DEST"

open "$DEST"
echo -e "\n${GREEN}${BOLD}  ✓ ${APP_NAME} ${VERSION} installed.${NC}\n"
echo -e "  Uninstall:  ${YELLOW}rm -rf \"$DEST\"${NC}"
echo -e "  Remove data too:  ${YELLOW}rm -rf ~/Library/Containers/com.zennox.musicplayer ~/Library/Application\\ Support/Zennox${NC}\n"
}

main "$@"
