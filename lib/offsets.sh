#!/usr/bin/env bash
# lib/offsets.sh — flash-offset caching
#
# _extract_flash_args() (lib/flash.sh) is expensive: it spins up proot-distro
# Ubuntu and runs `pio run -v -t upload --upload-port /dev/null` just to
# scrape the write_flash line out of esptool's verbose output. That's the
# whole compile-environment bootstrap, every single time, even when nothing
# about the flash layout changed since the last run.
#
# The flash layout only actually depends on:
#   - which board/platform/chip the env resolves to (platformio.ini)
#   - the partition table, if the env overrides it via board_build.partitions
#     (a project-relative .csv, or occasionally .ini per some templates)
#
# So we fingerprint those two inputs and cache the resulting OFFSET:FILE
# pairs keyed on that fingerprint. Next run, if platformio.ini and the
# referenced partition file both hash the same as last time, we skip the
# proot dry-run entirely and reuse the cached offsets. Any change to either
# file invalidates the cache automatically.
#
# Cache lives at <project_dir>/.tpio/cache/offsets-<env>.json — add
# `.tpio/` to your project's .gitignore.

_sha256() {
  if command -v sha256sum &>/dev/null; then
    sha256sum | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 | awk '{print $1}'
  else
    # Not cryptographically meaningful here, just needs to change when the
    # input changes — fine as a last-resort fallback if neither tool exists.
    md5sum | awk '{print $1}'
  fi
}

#  ini parsing 

# Prints the value of `key` inside `[section]` of an ini file, or nothing
# if the section/key isn't present. Hand-rolled because Termux/proot don't
# ship an ini parser by default and pulling one in is overkill for one key.
_ini_section_value() {
  local ini_file="$1" section="$2" key="$3"
  awk -v section="[$section]" -v key="$key" '
    BEGIN { in_sec = 0 }
    /^\[.*\]/ {
      in_sec = ($0 == section) ? 1 : 0
      next
    }
    in_sec {
      line = $0
      sub(/[[:space:]]*;.*/, "", line)
      if (match(line, "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*")) {
        val = substr(line, RLENGTH + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        print val
        exit
      }
    }
  ' "$ini_file"
}

# Resolves the partition-table file for a given env: checks [env:<env>]
# first, then falls back to the shared [env] section PlatformIO projects
# commonly use for settings applied to every environment.
_ini_partitions_file() {
  local ini_file="$1" env="$2"
  local value=""

  if [[ -n "$env" ]]; then
    value="$(_ini_section_value "$ini_file" "env:$env" "board_build.partitions")"
  fi
  if [[ -z "$value" ]]; then
    value="$(_ini_section_value "$ini_file" "env" "board_build.partitions")"
  fi
  echo "$value"
}

#  fingerprint 

# Combines env name + platformio.ini contents + (if present) the custom
# partition table contents into one hash. Changing the board, platform,
# upload settings, or the partition table all change this — anything else
# in platformio.ini technically does too, which is fine: worst case we
# just re-detect once more than strictly necessary.
_offset_fingerprint() {
  local project_dir="$1" env="$2"
  local ini_file="$project_dir/platformio.ini"
  local ini_hash part_hash="none" part_file

  ini_hash="$(_sha256 < "$ini_file")"

  part_file="$(_ini_partitions_file "$ini_file" "$env")"
  if [[ -n "$part_file" ]]; then
    [[ "$part_file" == /* ]] || part_file="$project_dir/$part_file"
    if [[ -f "$part_file" ]]; then
      part_hash="$(_sha256 < "$part_file")"
    else
      # Referenced but missing — still fingerprint it so a later fix
      # (file appears) is picked up as a change.
      part_hash="missing:$part_file"
    fi
  fi

  printf '%s' "${env:-default}:${ini_hash}:${part_hash}" | _sha256
}

#  cache file I/O 

# Not real JSON — just bash assignments, sourced back in. Matches the rest
# of this codebase (no jq dependency anywhere else) and avoids writing a
# JSON parser in bash for two fields.
_offset_cache_file() {
  local project_dir="$1" env="$2"
  echo "$project_dir/.tpio/cache/offsets-${env:-default}.json"
}

_write_offset_cache() {
  local cache_file="$1" fingerprint="$2" pairs="$3"
  mkdir -p "$(dirname "$cache_file")"
  {
    printf 'TPIO_CACHE_FINGERPRINT=%q\n' "$fingerprint"
    printf 'TPIO_CACHE_PAIRS=%q\n' "$pairs"
  } > "$cache_file"
}

# Prints "<fingerprint>\n<pairs>" on success, nothing (and returns 1) if the
# cache file is missing or unreadable.
_read_offset_cache() {
  local cache_file="$1"
  [[ -f "$cache_file" ]] || return 1

  # Run in a subshell so these vars can never leak into the caller even if
  # sourcing partially fails.
  (
    TPIO_CACHE_FINGERPRINT=""
    TPIO_CACHE_PAIRS=""
    # shellcheck disable=SC1090
    source "$cache_file" 2>/dev/null || exit 1
    [[ -n "$TPIO_CACHE_FINGERPRINT" ]] || exit 1
    printf '%s\n%s\n' "$TPIO_CACHE_FINGERPRINT" "$TPIO_CACHE_PAIRS"
  )
}

_invalidate_offset_cache() {
  local project_dir="$1" env="$2"
  local cache_file
  cache_file="$(_offset_cache_file "$project_dir" "$env")"
  [[ -f "$cache_file" ]] && rm -f "$cache_file"
  return 0
}

# True if every FILE half of each "OFFSET:FILE" pair still exists on disk.
# Guards against reusing offsets from a cache whose build artifacts were
# since cleaned (`pio run -t clean`, deleted .pio/, etc).
_offset_pairs_files_exist() {
  local pairs="$1" p file
  [[ -n "$pairs" ]] || return 1
  for p in $pairs; do
    file="${p#*:}"
    [[ -f "$file" ]] || return 1
  done
  return 0
}
