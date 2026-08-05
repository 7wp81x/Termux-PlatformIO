#!/usr/bin/env bash
# lib/monitor.sh — post-flash serial monitor hand-off for `--monitor`
#
# tpio doesn't ship its own monitor. It hands off to whatever
# BridgeProtocol-aware or plain-text monitor script you already use (e.g.
# bridge_monitor.py / serial_monitor.py from Termux-Serial-Monitor).
#
# Resolution order:
#   1. --monitor-cmd '<cmd>' passed on the tpio command line
#   2. MONITOR_CMD="..." set in ~/.tpio_config
#   3. bridge_monitor.py found on $PATH
#   4. serial_monitor.py found on $PATH
#   5. give up with a hint

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

  if command -v bridge_monitor.py &>/dev/null; then
    echo "python3 $(command -v bridge_monitor.py)"
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
    log_warn "--monitor requested but no monitor script found — skipping."
    log_warn "Set one of:"
    log_warn "  tpio run --monitor --monitor-cmd 'python3 /path/to/bridge_monitor.py'"
    log_warn "  echo 'MONITOR_CMD=\"python3 \$HOME/bridge_monitor.py\"' >> ~/.tpio_config"
    log_warn "…or put bridge_monitor.py / serial_monitor.py on your \$PATH."
    return 1
  fi

  log_section "Launching monitor"
  log_info "$monitor_cmd $*"
  # $monitor_cmd is intentionally unquoted — it may be "python3 /path/to/x.py"
  # and needs to split into separate argv entries.
  # shellcheck disable=SC2086
  exec $monitor_cmd "$@"
}
