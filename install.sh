#!/usr/bin/env bash
# install.sh — add tpio to PATH by symlinking into $PREFIX/bin (Termux-aware)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPIO_BIN="$REPO_DIR/bin/tpio"

# Termux uses $PREFIX/bin; fall back to ~/.local/bin on generic Linux
if [ -d "${PREFIX:-}/bin" ]; then
  TARGET_DIR="$PREFIX/bin"
elif [ -d "$HOME/.local/bin" ]; then
  TARGET_DIR="$HOME/.local/bin"
else
  mkdir -p "$HOME/.local/bin"
  TARGET_DIR="$HOME/.local/bin"
fi

chmod +x "$TPIO_BIN"

ln -sf "$TPIO_BIN" "$TARGET_DIR/tpio"
echo "✓ tpio installed → $TARGET_DIR/tpio"
echo ""
echo "Next steps:"
echo "  1. tpio setup          # bootstrap proot Ubuntu + PlatformIO"
echo "  2. cd your-pio-project"
echo "  3. tpio run            # compile + flash"
