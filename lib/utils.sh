#!/usr/bin/env bash
# lib/utils.sh — shared helpers for tpio

#  colours 
if [ -t 1 ]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'
  C_RED='\033[0;31m'
  C_CYAN='\033[0;36m'
else
  C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_CYAN=''
fi

log_info()    { echo -e "${C_CYAN}[tpio]${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}[tpio]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[tpio]${C_RESET} $*"; }
log_section() { echo -e "\n${C_BOLD}${C_CYAN} $* ${C_RESET}"; }

die() {
  echo -e "${C_RED}[tpio] ERROR:${C_RESET} $*" >&2
  exit 1
}

#  sanity checks 

require_termux() {
  [ -d "/data/data/com.termux" ] || die "tpio must be run inside Termux."
}

require_cmd() {
  command -v "$1" &>/dev/null || die "'$1' not found. Run: tpio setup"
}

#  help 

print_help() {
  cat <<'EOF'

  tpio — Termux PlatformIO wrapper

  Compiles ESP32/ESP8266 projects inside proot-distro Ubuntu,
  then flashes the resulting .bin via nrflash (no root required).

  COMMANDS
    tpio setup              Bootstrap proot-distro Ubuntu + PlatformIO
    tpio run [args]         Compile project and flash to device
    tpio run --build-only   Compile only, skip flashing
    tpio run -e <env>       Target a specific PlatformIO environment
    tpio flash              Flash the last compiled .bin (skip compile)
    tpio flash --bin <path> Flash a specific .bin file

  FLASH FLAGS (tpio run / tpio flash)
    --monitor, -m            Launch a serial monitor right after flashing
    --monitor-cmd '<cmd>'    Monitor command to use, e.g.:
                                --monitor-cmd 'python3 ~/bridge_monitor.py'
                              Falls back to MONITOR_CMD in ~/.tpio_config,
                              then bridge_monitor.py / serial_monitor.py on
                              $PATH if neither is set.
    -- <args>                Anything after a literal -- is passed through
                              to the monitor command, e.g.:
                                tpio run --monitor -- --hex-unknown
    --fresh-offsets           Ignore the cached flash offsets for this env
                              and re-detect them from PlatformIO

  EXAMPLES
    tpio setup
    tpio run
    tpio run -e esp32dev
    tpio run -e esp32dev --build-only
    tpio run --monitor
    tpio run -e esp32c3 --monitor --monitor-cmd 'python3 ~/bridge_monitor.py'
    tpio flash
    tpio flash --bin .pio/build/esp32dev/firmware.bin
    tpio flash --monitor -- --timestamps

  FLASH OFFSET CACHING
    Detecting flash offsets normally means booting proot-distro Ubuntu just
    to ask PlatformIO what it would run. tpio caches the result per
    environment at <project>/.tpio/cache/offsets-<env>.json, keyed on a
    fingerprint of platformio.ini plus the env's board_build.partitions
    file (if any). Unchanged on the next run → cached offsets are reused
    and the proot boot is skipped entirely. Either file changes → offsets
    are re-detected automatically and the cache is refreshed.
    Add .tpio/ to your project's .gitignore. Force a re-detect any time
    with --fresh-offsets.

  NOTES
    • Run from your PlatformIO project directory (where platformio.ini lives).
    • proot-distro Ubuntu is used for compilation only — nrflash handles
      all USB access directly from Termux (no tty node needed).
    • nrflash must be on your PATH or set NRFLASH_PATH in ~/.tpio_config.

EOF
}
