#!/usr/bin/env bash
# lib/proot.sh — proot-distro Ubuntu bootstrap + pio compile

DISTRO="ubuntu"
PROOT_USER="root"

#  setup command 

cmd_setup() {
  require_termux
  log_section "tpio setup"

  # 1. proot-distro itself
  if ! command -v proot-distro &>/dev/null; then
    log_info "Installing proot-distro..."
    pkg install -y proot-distro || die "Failed to install proot-distro."
  else
    log_ok "proot-distro already installed."
  fi

  # 2. Ubuntu distro
  if proot-distro login "$DISTRO" -- true 2>/dev/null; then
    log_ok "Ubuntu already installed in proot-distro."
  else
    log_info "Installing Ubuntu via proot-distro (this may take a while)..."
    proot-distro install "$DISTRO" || die "Failed to install Ubuntu distro."
  fi

  # 3. Python + pip inside Ubuntu
  log_info "Updating Ubuntu and installing Python3 + pip..."
  _proot_run bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip python3-venv curl git
  " || die "Failed to install Python3 inside Ubuntu."

  # 4. PlatformIO inside Ubuntu (isolated venv to avoid pip externally-managed error)
  log_info "Installing PlatformIO inside Ubuntu venv..."
  _proot_run bash -c "
    python3 -m venv /root/.tpio-venv
    /root/.tpio-venv/bin/pip install --quiet --upgrade pip
    /root/.tpio-venv/bin/pip install --quiet platformio
  " || die "Failed to install PlatformIO inside Ubuntu."

  # 5. Write a thin pio shim so 'pio' works inside proot without activating venv each time
  _proot_run bash -c "
    cat > /usr/local/bin/pio << 'SH'
#!/usr/bin/env bash
exec /root/.tpio-venv/bin/pio \"\$@\"
SH
    chmod +x /usr/local/bin/pio
  "

  # 6. nrflash check (in Termux, not proot)
  log_section "Checking nrflash"
  _check_nrflash

  log_ok "Setup complete! Run 'tpio run' from your PlatformIO project."
}

#  compile via proot 

# Run pio inside proot-distro Ubuntu, mounting the current project dir.
# $@ — args to forward to `pio run`
proot_compile() {
  local project_dir
  project_dir="$(pwd)"

  [ -f "$project_dir/platformio.ini" ] || \
    die "No platformio.ini found in $(pwd). Run tpio from your project root."

  _proot_installed || die "Ubuntu not installed. Run: tpio setup"

  log_section "Compiling with PlatformIO (proot Ubuntu)"
  log_info "Project: $project_dir"

  # Why PLATFORMIO_CORE_DIR is set to /root/.platformio (inside proot):
  #
  # proot rewrites symlinks inside extracted tarballs using a .l2s temp
  # scheme. When the destination is a bind-mounted Termux path, the .l2s
  # files land outside the proot rootfs and paths get mangled, causing the
  # "would link outside destination" error during toolchain extraction.
  #
  # Keeping the PlatformIO package cache fully inside the proot rootfs
  # (/root/.platformio) means all symlink rewriting stays on one filesystem
  # that proot controls. The project dir is still bind-mounted so
  # .pio/build outputs come back to Termux automatically.

  proot-distro login "$DISTRO" \
    --bind "$project_dir:$project_dir" \
    -- bash -c "export PLATFORMIO_CORE_DIR=/root/.platformio && cd '$project_dir' && pio run $*"

  log_ok "Compile finished."
}

#  internal helpers 

# Run a command inside Ubuntu proot (no project bind-mount needed).
_proot_run() {
  proot-distro login "$DISTRO" -- "$@"
}

_proot_installed() {
  proot-distro login "$DISTRO" -- true 2>/dev/null
}

_check_nrflash() {
  local nrflash_bin
  nrflash_bin="$(_resolve_nrflash)"

  if [ -n "$nrflash_bin" ]; then
    log_ok "nrflash found: $nrflash_bin"
  else
    log_warn "nrflash not found on PATH."
    log_warn "Clone https://github.com/7wp81x/Termux-ESP-Flasher and either:"
    log_warn "  • Add its directory to PATH, or"
    log_warn "  • Set NRFLASH_PATH=/path/to/nrflash in ~/.tpio_config"
  fi
}
