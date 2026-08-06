#!/usr/bin/env bash
# lib/monitor.sh — post-flash serial monitor hand-off for `--monitor`
#
# tpio doesn't ship its own monitor. It hands off to serial_monitor.py,
# the frame-aware BridgeProtocol monitor bundled in bin/ and installed
# on $PATH by install.sh.
#
# Resolution order:
#   1. --monitor-cmd '<cmd>' passed on the tpio command line
#   2. MONITOR_CMD="..." set in ~/.tpio_config
#   3. serial_monitor.py found on $PATH  (bundled — default)
#   4. give up with a hint

_resolve_monitor_cmd() {
  local override="$1"
  local config="$HOME/.tpio_config"

  if [[ -n "$override" ]]; then
    echo "$override"
    return
  fi

  if [[ -f "$config" ]]; then
    # shellcheck disable=SC1090
    source "$config"
  fi
  if [[ -n "${MONITOR_CMD:-}" ]]; then
    echo "$MONITOR_CMD"
    return
  fi

  if command -v serial_monitor.py &>/dev/null; then
    echo "python3 $(command -v serial_monitor.py)"
    return
  fi

  echo ""
}

# _launch_monitor <monitor_cmd_override> [extra args to pass through...]
#
# Replaces the current process (exec) so Ctrl+C, terminal resize, etc. go
# straight to the monitor instead of through a wrapper shell. This is only
# ever called as the last step of `tpio run`/`tpio flash`, so there's
# nothing left in this script that needs to run afterward.
_launch_monitor() {
  local override="$1"
  shift || true
  local monitor_cmd
  monitor_cmd="$(_resolve_monitor_cmd "$override")"

  if [[ -z "$monitor_cmd" ]]; then
    log_warn "--monitor requested but serial_monitor.py not found — skipping."
    log_warn "Re-run install.sh to put it on \$PATH, or set one of:"
    log_warn "  tpio run --monitor --monitor-cmd 'python3 /path/to/serial_monitor.py'"
    log_warn "  echo 'MONITOR_CMD=\"python3 \$HOME/serial_monitor.py\"' >> ~/.tpio_config"
    return 1
  fi

  log_section "Launching monitor"
  log_info "$monitor_cmd $*"
  # $monitor_cmd is intentionally unquoted — it may be "python3 /path/to/x.py"
  # and needs to split into separate argv entries.
  # shellcheck disable=SC2086
  exec $monitor_cmd "$@"
}
