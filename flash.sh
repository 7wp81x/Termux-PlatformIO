#!/usr/bin/env bash
# lib/flash.sh — .bin auto-detection + nrflash invocation

#  cmd_run: compile then flash 

cmd_run() {
  local build_only=0
  local pio_args=()
  local env=""

  # Parse tpio-specific flags; forward the rest to pio run
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build-only)
        build_only=1
        shift
        ;;
      -e|--environment)
        env="$2"
        pio_args+=("-e" "$2")
        shift 2
        ;;
      -e*)
        env="${1#-e}"
        pio_args+=("$1")
        shift
        ;;
      # suppress pio's own upload target — we handle flashing ourselves
      -t|--target)
        if [[ "$2" == "upload" ]]; then
          log_warn "--target upload ignored: tpio handles flashing via nrflash."
          shift 2
        else
          pio_args+=("$1" "$2")
          shift 2
        fi
        ;;
      *)
        pio_args+=("$1")
        shift
        ;;
    esac
  done

  # Compile
  proot_compile "${pio_args[@]+"${pio_args[@]}"}"

  if [[ "$build_only" -eq 1 ]]; then
    log_info "Build-only mode — skipping flash."
    return 0
  fi

  # Auto-detect .bin
  local bin_path
  bin_path="$(_find_bin "$env")"

  # Flash
  _do_flash "$bin_path"
}

#  cmd_flash: flash only 

cmd_flash() {
  local bin_path=""
  local env=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin|-b)
        bin_path="$2"
        shift 2
        ;;
      -e|--environment)
        env="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -z "$bin_path" ]]; then
    bin_path="$(_find_bin "$env")"
  fi

  _do_flash "$bin_path"
}

#  internal: .bin discovery 

_find_bin() {
  local env="${1:-}"
  local project_dir
  project_dir="$(pwd)"
  local build_dir="$project_dir/.pio/build"

  [ -d "$build_dir" ] || die "No .pio/build directory found. Run 'tpio run' first."

  # If env given, look directly
  if [[ -n "$env" ]]; then
    local candidate="$build_dir/$env/firmware.bin"
    [ -f "$candidate" ] || die "No firmware.bin found at: $candidate"
    echo "$candidate"
    return
  fi

  # No env given — find all firmware.bin files
  local -a bins
  mapfile -t bins < <(find "$build_dir" -maxdepth 2 -name "firmware.bin" 2>/dev/null | sort)

  case "${#bins[@]}" in
    0)
      die "No firmware.bin found under .pio/build/. Run 'tpio run' first."
      ;;
    1)
      log_info "Auto-detected: ${bins[0]}"
      echo "${bins[0]}"
      ;;
    *)
      # Multiple envs — pick the most recently modified
      local newest
      newest="$(ls -t "${bins[@]}" | head -1)"
      log_warn "Multiple environments found. Using most recent: $newest"
      log_warn "Pass -e <env> to target a specific one."
      echo "$newest"
      ;;
  esac
}

#  internal: nrflash invocation 

_resolve_nrflash() {
  # Config file override
  local config="$HOME/.tpio_config"
  if [ -f "$config" ]; then
    # shellcheck disable=SC1090
    source "$config"
  fi

  if [[ -n "${NRFLASH_PATH:-}" && -x "$NRFLASH_PATH" ]]; then
    echo "$NRFLASH_PATH"
    return
  fi

  # Fall back to PATH
  command -v nrflash 2>/dev/null || true
}

_do_flash() {
  local bin_path="$1"

  [ -f "$bin_path" ] || die "Binary not found: $bin_path"

  local nrflash_bin
  nrflash_bin="$(_resolve_nrflash)"
  [ -n "$nrflash_bin" ] || die "nrflash not found. Run 'tpio setup' or set NRFLASH_PATH in ~/.tpio_config"

  log_section "Flashing via nrflash"
  log_info "Binary : $bin_path"
  log_info "Flasher: $nrflash_bin"

  # Determine flash offset — factory/merged bins go at 0x0, plain app at 0x10000
  local offset
  offset="$(_guess_offset "$bin_path")"
  log_info "Offset : $offset"

  "$nrflash_bin" write --offset "$offset" "$bin_path" --verify

  log_ok "Flash complete."
}

_guess_offset() {
  local bin_path="$1"
  local fname
  fname="$(basename "$bin_path")"

  # factory / merged / combined images -> 0x0
  if [[ "$fname" == *factory* || "$fname" == *merged* || "$fname" == *combined* ]]; then
    echo "0x0"
    return
  fi

  # plain firmware.bin from pio -> app partition (0x10000 is the default)
  # users with custom partition tables should use tpio flash --bin manually
  echo "0x10000"
}
