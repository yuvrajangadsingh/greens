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

if [[ "${1:-}" == --local ]]; then
  INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  BIN_DIR="${GREENS_BIN_DIR:-$HOME/.local/bin}"
  mkdir -p "$BIN_DIR"
  ln -sf "$INSTALL_DIR/sync.sh" "$BIN_DIR/$BIN_NAME"
  echo "Installed $BIN_DIR/$BIN_NAME from this checkout."
  echo "Keep this checkout in place and ensure $BIN_DIR is on PATH."
  exec "$INSTALL_DIR/setup.sh"
elif [[ -n "${1:-}" ]]; then
  echo "Usage: bash install.sh [--local]" >&2
  exit 1
fi

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
if [[ "$(uname -s)" == Linux ]]; then
  BIN_DIR="${GREENS_BIN_DIR:-$HOME/.local/bin}"
  mkdir -p "$BIN_DIR"
fi
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
