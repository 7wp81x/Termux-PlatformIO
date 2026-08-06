#!/usr/bin/env bash
# install.sh — add tpio (+ bundled monitors) to PATH by symlinking into
# $PREFIX/bin (Termux-aware)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPIO_BIN="$REPO_DIR/bin/tpio"
BRIDGE_MONITOR_BIN="$REPO_DIR/bin/serial_monitor.py"

# Termux uses $PREFIX/bin; fall back to ~/.local/bin on generic Linux
if [ -d "${PREFIX:-}/bin" ]; then
  TARGET_DIR="$PREFIX/bin"
elif [ -d "$HOME/.local/bin" ]; then
  TARGET_DIR="$HOME/.local/bin"
else
  mkdir -p "$HOME/.local/bin"
  TARGET_DIR="$HOME/.local/bin"
fi

chmod +x "$TPIO_BIN" "$BRIDGE_MONITOR_BIN"

ln -sf "$TPIO_BIN" "$TARGET_DIR/tpio"
ln -sf "$BRIDGE_MONITOR_BIN" "$TARGET_DIR/serial_monitor.py"

echo "✓ tpio installed → $TARGET_DIR/tpio"
echo "✓ serial_monitor.py installed → $TARGET_DIR/serial_monitor.py"
echo ""
echo "serial_monitor.py is now on \$PATH, so 'tpio run --monitor' finds"
echo "it automatically — no MONITOR_CMD config needed."
echo "It needs the 'espbridge' package: pip install espbridge"
echo ""
echo "Next steps:"
echo "  1. tpio setup          # bootstrap proot Ubuntu + PlatformIO"
echo "  2. pip install espbridge nrflash"
echo "  3. cd your-pio-project"
echo "  4. tpio run --monitor  # compile + flash + watch output"
