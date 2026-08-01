#!/usr/bin/env bash
# lib/flash.sh — offset-aware flash via pio -v upload interception + nrflash

#  cmd_run: compile then flash 

cmd_run() {
  local build_only=0
  local pio_args=()
  local env=""

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

  proot_compile "${pio_args[@]+"${pio_args[@]}"}"

  if [[ "$build_only" -eq 1 ]]; then
    log_info "Build-only mode — skipping flash."
    return 0
  fi

  local flash_args
  flash_args="$(_extract_flash_args "$env")"

  _do_flash "$flash_args"
}

#  cmd_flash: flash only 

cmd_flash() {
  local env=""
  local bin_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e|--environment)
        env="$2"
        shift 2
        ;;
      --bin|-b)
        bin_path="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -n "$bin_path" ]]; then
    # Manual path: just flash it at 0x10000 (user knows what they're doing)
    _do_flash "0x10000:$bin_path"
    return
  fi

  local flash_args
  flash_args="$(_extract_flash_args "$env")"
  _do_flash "$flash_args"
}

#  extract flash args from pio -v upload dry-run 
#
# Runs `pio run -v -t upload` inside proot with a fake port so esptool bails
# immediately after printing the command — we capture the write_flash line
# and turn it into nrflash OFFSET:FILE pairs.
#
# The verbose output contains a line like:
#   esptool.py ... write_flash ... 0x1000 bootloader.bin 0x8000 partitions.bin ...
#
# We parse every (hex_offset, file_path) pair from that line.

_extract_flash_args() {
  local env="${1:-}"
  local project_dir
  project_dir="$(pwd)"

  [ -f "$project_dir/platformio.ini" ] || \
    die "No platformio.ini found. Run from your project root."

  log_info "Reading flash layout from PlatformIO..." >&2

  local env_flag=""
  [[ -n "$env" ]] && env_flag="-e $env"

  # Run verbose upload with a bogus port — esptool will print the full
  # command then fail to connect, which is fine; we only need stdout.
  local pio_output
  pio_output="$(
    proot-distro login ubuntu --no-link2symlink \
      --bind "$project_dir:$project_dir" \
      -- bash -c "
        export PLATFORMIO_CORE_DIR=/root/.platformio
        cd '$project_dir'
        pio run -v $env_flag -t upload --upload-port /dev/null 2>&1 || true
      "
  )"

  # Find the write_flash line
  local wf_line
  wf_line="$(echo "$pio_output" | grep -o 'write.flash[^"]*' | head -1)"

  if [[ -z "$wf_line" ]]; then
    log_warn "Could not parse flash layout from pio output — falling back to file scan." >&2
    _fallback_flash_args "$project_dir" "$env"
    return
  fi

  # Parse (offset file) pairs from the write_flash args.
  # Format: write_flash [flags...] 0xOFFSET /path/to/file 0xOFFSET /path/to/file ...
  local -a pairs=()
  local tokens
  read -ra tokens <<< "$wf_line"
  local i=0
  while [[ $i -lt ${#tokens[@]} ]]; do
    local tok="${tokens[$i]}"
    # hex offset
    if [[ "$tok" =~ ^0x[0-9a-fA-F]+$ ]]; then
      local offset="$tok"
      local file="${tokens[$((i+1))]:-}"
      if [[ -n "$file" && "$file" != 0x* ]]; then
        # Resolve relative paths against project dir
        if [[ "$file" != /* ]]; then
          file="$project_dir/$file"
        fi
        if [[ -f "$file" ]]; then
          pairs+=("${offset}:${file}")
        else
          log_warn "Skipping missing file: $file" >&2
        fi
        ((i+=2))
        continue
      fi
    fi
    ((i++))
  done

  if [[ ${#pairs[@]} -eq 0 ]]; then
    log_warn "No valid offset:file pairs found — falling back to file scan." >&2
    _fallback_flash_args "$project_dir" "$env"
    return
  fi

  log_info "Flash layout:" >&2
  for p in "${pairs[@]}"; do
    log_info "  $p" >&2
  done

  # Return space-separated pairs for _do_flash
  echo "${pairs[*]}"
}

#  fallback: scan build dir for known files 
#
# Used when the verbose upload parse fails. Handles the most common layouts
# based on what files actually exist in the build dir.

_fallback_flash_args() {
  local project_dir="$1"
  local env="${2:-}"
  local base="$project_dir/.pio/build"

  # Find build dir
  local build_dir=""
  if [[ -n "$env" ]]; then
    build_dir="$base/$env"
  else
    local -a dirs
    mapfile -t dirs < <(find "$base" -maxdepth 2 -name "firmware.bin" 2>/dev/null \
      | sed 's|/firmware\.bin$||' | sort)
    case "${#dirs[@]}" in
      0) die "No firmware.bin found under .pio/build/." ;;
      1) build_dir="${dirs[0]}" ;;
      *) build_dir="$(ls -td "${dirs[@]}" | head -1)"
         log_warn "Multiple envs, using most recent: $(basename "$build_dir")" >&2 ;;
    esac
  fi

  [ -d "$build_dir" ] || die "Build directory not found: $build_dir"

  local bootloader="$build_dir/bootloader.bin"
  local partitions="$build_dir/partitions.bin"
  local firmware="$build_dir/firmware.bin"

  local -a pairs=()

  if [[ -f "$bootloader" && -f "$partitions" && -f "$firmware" ]]; then
    # Detect chip from build dir name to pick correct bootloader offset
    local env_name
    env_name="$(basename "$build_dir")"
    local bl_offset
    bl_offset="$(_bootloader_offset "$env_name")"
    log_warn "Using fallback offsets: bootloader=$bl_offset partitions=0x8000 firmware=0x10000" >&2
    pairs=("${bl_offset}:${bootloader}" "0x8000:${partitions}" "0x10000:${firmware}")
  elif [[ -f "$firmware" ]]; then
    log_warn "Only firmware.bin found, flashing at 0x10000." >&2
    pairs=("0x10000:${firmware}")
  else
    die "No flashable binaries in: $build_dir"
  fi

  echo "${pairs[*]}"
}

# Guess bootloader offset from environment name when we can't get it from pio.
_bootloader_offset() {
  local env_name="${1,,}"  # lowercase
  # C3, C6, S3, H2, C2, C5, C61 boot at 0x0; classic ESP32, S2, P4 at 0x1000
  if [[ "$env_name" =~ (c3|c6|s3|h2|c2|c5|c61) ]]; then
    echo "0x0"
  elif [[ "$env_name" =~ esp8266 ]]; then
    echo "0x0"  # ESP8266 has no separate bootloader in the pio build
  else
    echo "0x1000"  # ESP32, S2, P4
  fi
}

#  nrflash invocation 

_resolve_nrflash() {
  local config="$HOME/.tpio_config"
  if [ -f "$config" ]; then
    # shellcheck disable=SC1090
    source "$config"
  fi
  if [[ -n "${NRFLASH_PATH:-}" && -x "$NRFLASH_PATH" ]]; then
    echo "$NRFLASH_PATH"
    return
  fi
  command -v nrflash 2>/dev/null || true
}

_do_flash() {
  local flash_args="$1"

  local nrflash_bin
  nrflash_bin="$(_resolve_nrflash)"
  [ -n "$nrflash_bin" ] || \
    die "nrflash not found. Run 'tpio setup' or set NRFLASH_PATH in ~/.tpio_config"

  log_section "Flashing via nrflash"

  # Split space-separated OFFSET:FILE pairs into array
  read -ra pairs <<< "$flash_args"

  "$nrflash_bin" write "${pairs[@]}" --verify

  log_ok "Flash complete."
}