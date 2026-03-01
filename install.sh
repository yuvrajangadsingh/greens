#!/bin/bash
#
# One-liner installer for greens
# Usage: curl -fsSL https://raw.githubusercontent.com/yuvrajangadsingh/greens/main/install.sh | bash
#
set -euo pipefail

INSTALL_DIR="$HOME/.contrib-mirror/src"
REPO_URL="https://github.com/yuvrajangadsingh/greens.git"
BIN_NAME="greens"

echo ""
echo "Installing greens..."
echo ""

# Check dependencies
for cmd in git bash; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not installed." >&2
    exit 1
  fi
done

# Clone or update
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "  Updating existing installation..."
  git -C "$INSTALL_DIR" pull --quiet
else
  echo "  Cloning repository..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/sync.sh" "$INSTALL_DIR/setup.sh"

# Symlink to PATH
BIN_DIR="/usr/local/bin"
if [[ ! -w "$BIN_DIR" ]]; then
  # Try homebrew bin on macOS
  if [[ -d "/opt/homebrew/bin" && -w "/opt/homebrew/bin" ]]; then
    BIN_DIR="/opt/homebrew/bin"
  else
    echo "  Need sudo to symlink to $BIN_DIR"
    sudo ln -sf "$INSTALL_DIR/sync.sh" "$BIN_DIR/$BIN_NAME"
    echo "  [ok] Installed to $BIN_DIR/$BIN_NAME"
    echo ""
    exec "$INSTALL_DIR/setup.sh"
  fi
fi

ln -sf "$INSTALL_DIR/sync.sh" "$BIN_DIR/$BIN_NAME"
echo "  [ok] Installed to $BIN_DIR/$BIN_NAME"
echo ""

# Run setup
exec "$INSTALL_DIR/setup.sh"
