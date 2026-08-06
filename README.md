# Termux-PlatformIO

Compile ESP32/ESP8266 PlatformIO projects on Android. No root, no desktop.

![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Android%20%2F%20Termux-green.svg)
![ESP32](https://img.shields.io/badge/chip-ESP32%20%7C%20ESP8266-orange.svg)

```
termux shell
  └─ tpio run
       ├─ proot-distro Ubuntu  →  pio run  →  firmware.bin
       ├─ nrflash              →  USB flash (no /dev/tty* needed)
       └─ --monitor            →  serial_monitor.py
```

PlatformIO runs inside a proot-distro Ubuntu container (full Linux ABI, no root).
Flashing is handled by [nrflash](https://github.com/7wp81x/Termux-ESP-Flasher), a Termux-native ESP flasher that talks directly to the chip over raw USB with no serial device node required.

## Screenshots

<img src="https://github.com/7wp81x/Termux-PlatformIO/raw/main/img/1.jpg" width="250"> <img src="https://github.com/7wp81x/Termux-PlatformIO/raw/main/img/2.jpg" width="250"> <img src="https://github.com/7wp81x/Termux-PlatformIO/raw/main/img/3.jpg" width="250">

<img src="https://github.com/7wp81x/Termux-PlatformIO/raw/main/img/4.jpg" width="250"> <img src="https://github.com/7wp81x/Termux-PlatformIO/raw/main/img/5.jpg" width="250">

## Requirements

| Tool | Install |
| ---- | ------- |
| [Termux](https://f-droid.org/en/packages/com.termux/) | F-Droid |
| [Termux:API](https://f-droid.org/en/packages/com.termux.api/) | F-Droid (needed for USB access) |
| [nrflash](https://github.com/7wp81x/Termux-ESP-Flasher) | `pip install nrflash` |
| `espbridge` | `pip install espbridge` (required for `--monitor`) |

> Use the **F-Droid** versions of Termux and Termux:API. The Play Store builds are outdated.

`bin/serial_monitor.py` is the single bundled serial monitor — a frame-aware [BridgeProtocol](https://github.com/7wp81x/ESP-Bridge) monitor that works with both native USB-CDC boards (ESP32-S3/C3) and UART bridge chips (CP2102/CH340/CH9102/FTDI). `install.sh` puts it on your `$PATH` alongside `tpio`, so `tpio run --monitor` finds it automatically with no extra configuration needed beyond `pip install espbridge`.

## Install

```bash
# 1. Clone this repo
git clone https://github.com/7wp81x/Termux-PlatformIO
cd Termux-PlatformIO
bash install.sh                  # installs tpio + serial_monitor.py

# 2. Install nrflash and espbridge
pip install nrflash espbridge

# 3. Install Termux deps
pkg install python termux-api libusb proot-distro

# 4. Bootstrap proot Ubuntu + PlatformIO (one-time, ~5 min)
tpio setup
```

## Usage

```bash
# From your PlatformIO project directory (where platformio.ini lives):

tpio run                         # compile + flash
tpio run -e esp32dev             # target a specific environment
tpio run --build-only            # compile only, skip flash
tpio flash                       # flash last compiled .bin
tpio flash --bin path/to/fw.bin  # flash a specific binary

# Flash then jump straight into the serial monitor:
tpio run --monitor
tpio run -e esp32c3 --monitor --monitor-cmd 'python3 ~/serial_monitor.py'
tpio flash --monitor -- --hex-unknown --timestamps   # args after -- go to the monitor

# Force a fresh flash-offset detection instead of using the cache:
tpio run --fresh-offsets
```

### First run

When `tpio run` hits the USB flash step, Android will show a USB permission dialog. Tap **OK**. The permission sticks until you unplug.

### Flash + monitor in one go (`--monitor`)

Pass `--monitor` (or `-m`) to `tpio run` or `tpio flash` and, right after a successful flash, tpio hands off to `serial_monitor.py`. It's bundled in this repo and put on your `$PATH` by `install.sh`, so this works with **zero configuration** — no `MONITOR_CMD`, no `--monitor-cmd` needed, as long as you've run `pip install espbridge`.

Resolution order, if you want to override:

1. `--monitor-cmd '<cmd>'` passed on the command line
2. `MONITOR_CMD="..."` set in `~/.tpio_config`
3. `serial_monitor.py` on your `$PATH` (bundled — this is what fires by default)

If none of those resolve, tpio warns and exits — flashing itself still succeeded.

```bash
# ~/.tpio_config
MONITOR_CMD="python3 $HOME/serial_monitor.py"
```

Anything after a literal `--` is forwarded straight to the monitor command, so monitor-specific flags don't need to be known to tpio itself:

```bash
tpio flash --monitor -- --hex-unknown --timestamps
```

## How it works

### Compile step (`proot-distro`)

`tpio run` calls `proot-distro login ubuntu --no-link2symlink` with your project directory bind-mounted at its original path. PlatformIO runs inside the Ubuntu container and writes build outputs back to `.pio/build/<env>/` on your Termux filesystem. No copy step needed.

### Flash step (`nrflash`)

After a successful build, `tpio` runs `pio run -v -t upload` inside proot with a dummy port to intercept the exact esptool command PlatformIO would use. It parses every `OFFSET FILE` pair from the `write_flash` line and passes them directly to `nrflash`, so offsets are always correct regardless of chip or partition layout.

Supports:

- Native USB CDC: ESP32-S3, C3, S2
- UART bridge: ESP32, ESP8266 via CP2102, CH340, CH9102, FTDI

### Flash offset detection (cached)

Offsets are read directly from PlatformIO's verbose upload output, so they're always correct for your specific chip:

| Chip | Bootloader | Partitions | App |
| ---- | ---------- | ---------- | --- |
| ESP32, ESP32-S2 | `0x1000` | `0x8000` | `0x10000` |
| ESP32-C3, C6, S3, H2 | `0x0` | `0x8000` | `0x10000` |
| ESP8266 | n/a | n/a | `0x0` |

If PlatformIO output can't be parsed, tpio falls back to scanning the build directory and guessing offsets from the environment name.

Detecting offsets this way means booting proot-distro Ubuntu just to ask PlatformIO what it would run — not something you want to repeat on every single flash if nothing about your board or partition layout has changed. So tpio caches the result per environment at `<project>/.tpio/cache/offsets-<env>.json`, keyed on a fingerprint of:

- `platformio.ini`
- whichever file `board_build.partitions` points at for that env, if it overrides one

On the next `tpio run`/`tpio flash`:

- **Fingerprint unchanged** → cached offsets are reused, the proot boot and `pio run -v -t upload` dry-run are skipped entirely.
- **`platformio.ini` or the partition file changed** → tpio re-detects automatically and refreshes the cache.
- **Cached offsets point at build files that no longer exist** (e.g. after `pio run -t clean`) → also re-detects, so a stale cache can't point you at a deleted `.bin`.

Force a re-detect any time with `--fresh-offsets`, regardless of whether anything actually changed. Add `.tpio/` to your project's `.gitignore`.

## Config

Optional config file at `~/.tpio_config` (sourced as bash):

```bash
# ~/.tpio_config
NRFLASH_PATH=/data/data/com.termux/files/home/.local/bin/nrflash
MONITOR_CMD="python3 $HOME/serial_monitor.py"
```

Useful if `nrflash` isn't on your `$PATH` after pip install, or if you want `--monitor` to always launch with a specific command without passing `--monitor-cmd` every time.

## Troubleshooting

**`pio: command not found` inside proot**
Re-run `tpio setup`. It installs PlatformIO in a venv and creates a `/usr/local/bin/pio` shim inside Ubuntu.

**`nrflash not found`**
Run `pip install nrflash` and make sure pip's bin directory is on your `$PATH`. Or set `NRFLASH_PATH` in `~/.tpio_config`.

**USB permission dialog doesn't appear**
Unplug and replug the OTG cable, then retry `tpio flash`.

**Flashing fails after successful compile**
Try `tpio flash` standalone. The compile step exits cleanly even if flash fails. Also check that Termux:API is installed from F-Droid, not the Play Store.

**Wrong environment flashed (multiple envs in platformio.ini)**
Pass `-e <env>` explicitly: `tpio run -e esp32dev`.

**`--monitor requested but serial_monitor.py not found`**
Re-run `bash install.sh` — it symlinks `serial_monitor.py` onto your `$PATH`. Also confirm `pip install espbridge` was run, and that your shell's `$PATH` includes wherever `install.sh` put the symlinks (`$PREFIX/bin` on Termux). You can always override with `--monitor-cmd 'python3 /path/to/serial_monitor.py'` or `MONITOR_CMD` in `~/.tpio_config`.

**Flash offsets seem stale / wrong after editing platformio.ini**
This should self-correct automatically — tpio re-detects whenever `platformio.ini` or the referenced partition file changes. If it doesn't (e.g. you edited something the fingerprint doesn't cover, like `board_build.partitions` pointing at a file outside the project), force it with `tpio run --fresh-offsets`, or just delete `.tpio/cache/` in your project.

**Toolchain extraction stalls with `.l2s` warnings**
This is fixed by `--no-link2symlink` which tpio passes automatically. If you still see it, pull the latest: `git pull && bash install.sh`.

## Related projects

- [Termux-ESP-Flasher](https://github.com/7wp81x/Termux-ESP-Flasher) - `nrflash`, the flasher used under the hood
- [ESP-Bridge](https://github.com/7wp81x/ESP-Bridge) - framed USB bridge protocol for ESP32 and Termux
- [Termux-Serial-Monitor](https://github.com/7wp81x/Termux-Serial-Monitor) - serial monitor for ESP devices over USB in Termux
- [NRSuite](https://github.com/7wp81x/NRSuite) - no-root wireless security toolkit for Android powered by ESP32

## License

MIT
