#!/usr/bin/env python3
"""
serial_monitor.py - Frame-aware monitor for the BridgeProtocol framed binary
protocol (magic 0xAD 0xDE, see BridgeProtocol.h / espbridge/protocol.py),
for ESP32-C3/S3 (native USB) or classic ESP32/ESP8266 behind a
CP2102/CH340/CH9102/FTDI bridge. Termux (no-root, termux-api) or root.

Unlike serial_monitor.py, this does NOT line-buffer on b"\n" - it feeds raw
bytes into espbridge.FrameParser and prints whatever complete frames come
out, regardless of whether the stream ever contains a newline. Plain
BridgeProtocol CMD/RESP/EVENT/ACK frames carry no newline at all, so the
line-buffered monitor can sit silently for a long time even though data is
flowing - see the two write-ups below.

It also does NOT leave DTR permanently asserted after bringing up a UART
bridge chip. See --hold-dtr below for why.

Usage:
    python serial_monitor.py
    python serial_monitor.py --device /dev/bus/usb/002/071
    python serial_monitor.py --reset
    python serial_monitor.py --send-cmd PING
    python serial_monitor.py --hex-unknown

Interactive input (unless --no-input):
    Type a bare command name to send a CMD frame with empty args:
        PING
    Or a command name followed by JSON args:
        SET_LED {"on": true, "brightness": 128}
    Ctrl+C to stop.

Why this exists instead of serial_monitor.py:
  1. serial_monitor.py buffers incoming bytes and only prints once it finds
     a b"\n" in the stream. BridgeProtocol frames
     ([MAGIC 2B][TYPE 1B][ID 1B][LENGTH 4B LE][PAYLOAD]) never contain one,
     so a running BridgeProtocol firmware can transmit for a long time with
     the monitor showing nothing at all - not because data isn't arriving,
     but because nothing has triggered a flush yet. This script instead
     hands every chunk straight to FrameParser.feed(), which tracks frame
     boundaries itself and returns complete frames as soon as they're
     fully received, independent of newlines.
  2. usb_device.init_uart_bridge() ends by re-asserting DTR ("Always
     re-assert DTR so CH340 forwards RX data to host") and leaving it
     asserted indefinitely. On the standard CH340/CP2102 ESP32 auto-reset
     circuit, DTR drives GPIO0 - so this leaves GPIO0 held LOW after init.
     That's harmless while the chip is already running (GPIO0 only matters
     at the moment of reset/boot), but the *next* reset - including a
     physical EN button press, which bypasses the CH340 entirely - will
     sample GPIO0 low and drop the chip into the UART download bootloader
     ("waiting for download") instead of booting the app. This script
     releases DTR/RTS back to idle right after bringing the bridge up, so
     GPIO0 is high and a stray reset boots normally. If your board's RX
     genuinely does need DTR held (some clones are cap-coupled oddly),
     pass --hold-dtr to restore the old behavior - just know that trades
     away safe physical-button resets.
"""

import os
import sys
import json
import time
import argparse
import threading

import usb.core

import espbridge as eb


def parse_args():
    p = argparse.ArgumentParser(description="Frame-aware BridgeProtocol monitor for ESP32 OTG devices")
    p.add_argument("--device", default=None,
                   help="Specific USB device path (termux backend), e.g. /dev/bus/usb/002/071")
    p.add_argument("--baud", type=int, default=115200,
                   help="UART baud rate for bridge chips. Ignored on native USB-CDC boards. Default: 115200")
    p.add_argument("--reset", action="store_true",
                   help="Extra hardware reset pulse before monitoring starts (bridge chips only). "
                        "init_uart_bridge() already does one reset pulse unconditionally; this adds "
                        "a second one on top, matching the original serial_monitor.py --reset flag.")
    p.add_argument("--hold-dtr", action="store_true",
                   help="Restore the old behavior of leaving DTR permanently asserted after bridge "
                        "init (holds GPIO0 low on most boards). Only use this if you've confirmed "
                        "your board genuinely needs it - it means a physical EN reset will drop the "
                        "chip into the UART download bootloader instead of your app.")
    p.add_argument("--read-size", type=int, default=16 * 1024,
                   help="Bytes per USB bulk read (default: 16384)")
    p.add_argument("--timeout-ms", type=int, default=100,
                   help="USB read timeout in ms (default: 100)")
    p.add_argument("--write-timeout-ms", type=int, default=2000,
                   help="USB write timeout in ms (default: 2000)")
    p.add_argument("--no-input", action="store_true",
                   help="Disable the input thread (read-only monitor)")
    p.add_argument("--timestamps", action="store_true",
                   help="Prefix each printed frame with an HH:MM:SS timestamp")
    p.add_argument("--hex-unknown", action="store_true",
                   help="Hex-dump PCAP/HTML binary frames instead of just showing their length")
    p.add_argument("--send-cmd", default=None,
                   help="Send one CMD frame with this name on startup (JSON args via --send-args), "
                        "print the RESP, then continue monitoring")
    p.add_argument("--send-args", default=None,
                   help="JSON object of args to pair with --send-cmd, e.g. '{\"on\": true}'")
    return p.parse_args()


def hexdump(data: bytes, width: int = 16) -> str:
    lines = []
    for i in range(0, len(data), width):
        chunk = data[i:i + width]
        hex_part = " ".join(f"{b:02X}" for b in chunk)
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append(f"{i:08X}  {hex_part:<{width*3}}  {ascii_part}")
    return "\n".join(lines)


TYPE_NAMES = {
    eb.TYPE_CMD:   "CMD",
    eb.TYPE_RESP:  "RESP",
    eb.TYPE_EVENT: "EVENT",
    eb.TYPE_PCAP:  "PCAP",
    eb.TYPE_ACK:   "ACK",
    eb.TYPE_HTML:  "HTML",
}


def ts_prefix(args) -> str:
    if not args.timestamps:
        return ""
    return f"[{time.strftime('%H:%M:%S')}] "


def print_frame(frame: dict, args):
    tname = TYPE_NAMES.get(frame["type"], f"0x{frame['type']:02X}")
    prefix = ts_prefix(args)

    if frame["json"] is not None:
        body = json.dumps(frame["json"], separators=(",", ":"))
        print(f"{prefix}[{tname} id={frame['id']}] {body}", flush=True)
    elif frame["type"] in (eb.TYPE_PCAP, eb.TYPE_HTML) and not args.hex_unknown:
        print(f"{prefix}[{tname} id={frame['id']}] <{frame['length']} bytes binary>", flush=True)
    else:
        print(f"{prefix}[{tname} id={frame['id']}] <{frame['length']} bytes, not valid JSON>", flush=True)
        print(hexdump(frame["payload"]), flush=True)


def input_writer(sender: "eb.Sender", stop_event: threading.Event):
    """
    Background thread: reads lines from stdin, treats each as either a bare
    command name or "COMMAND {json args}", and sends a CMD frame.
    """
    print("[*] Type a command name (optionally followed by JSON args) and press Enter.", flush=True)
    while not stop_event.is_set():
        try:
            line = sys.stdin.readline()
        except (EOFError, KeyboardInterrupt):
            break

        if line == "":
            break

        line = line.strip()
        if not line:
            continue

        parts = line.split(None, 1)
        cmd = parts[0]
        args_dict = {}
        if len(parts) > 1:
            try:
                args_dict = json.loads(parts[1])
            except json.JSONDecodeError as e:
                print(f"[!] Couldn't parse args as JSON, sending empty args instead: {e}", flush=True)

        frame = eb.build_cmd(cmd, args_dict)
        if sender.send_bytes(frame):
            print(f"[>>] CMD {cmd} {json.dumps(args_dict)}", flush=True)
        else:
            print("[!] Send failed", flush=True)


def bring_up_bridge(device, args):
    """
    Initialize a UART bridge chip (CP2102/CH340/CH9102/FTDI) and leave it in
    a safe idle state - DTR/RTS both released - so GPIO0 isn't held low
    after we're done. See the module docstring for why that matters.
    """
    eb.init_uart_bridge(device)

    if args.baud != 115200:
        print(f"[*] Setting UART bridge baud rate to {args.baud}...", flush=True)
        try:
            eb.set_uart_bridge_baud(device, args.baud)
        except Exception as e:
            print(f"[-] Warning: failed to set baud {args.baud}: {e}", flush=True)

    if args.reset:
        print("[*] Extra reset pulse...", flush=True)
        try:
            eb.set_dtr_rts(device, dtr=True, rts=True)
            time.sleep(0.1)
            eb.set_dtr_rts(device, dtr=False, rts=False)
            time.sleep(0.5)
        except Exception as e:
            print(f"[-] Warning: reset failed: {e}", flush=True)

    if args.hold_dtr:
        # Old behavior, opt-in only - see --hold-dtr help text.
        try:
            eb.set_dtr_rts(device, dtr=True, rts=False)
        except Exception as e:
            print(f"[-] Warning: could not hold DTR: {e}", flush=True)
    else:
        # Release both lines so GPIO0 (and EN) sit at their idle/high
        # state. This is what makes a subsequent physical EN reset boot
        # the app instead of dropping into the UART download bootloader.
        try:
            eb.set_dtr_rts(device, dtr=False, rts=False)
        except Exception as e:
            print(f"[-] Warning: could not release DTR/RTS: {e}", flush=True)


def main():
    args = parse_args()

    backend = eb.detect_backend()
    print(f"[*] Backend: {backend}" + (" (no-root)" if backend == "termux" else " (root)"), flush=True)

    if backend == "termux":
        device_path = args.device or eb.auto_detect_device()
        print(f"[+] Found device: {device_path}", flush=True)

        fd_str = os.environ.get("TERMUX_USB_FD")
        if fd_str is None:
            print("[*] Requesting USB permission...", flush=True)
            eb.relaunch_with_fd(device_path, os.path.abspath(__file__))
            return  # relaunch_with_fd execs, never returns

        fd = int(fd_str)
        device = eb.wrap_fd(fd)
        fd_wrapped = True
    else:
        device = eb.wrap_direct()
        fd_wrapped = False

    print(f"[*] Device: {eb.describe_device(device)}", flush=True)

    ep_in, ep_out, intf = eb.get_cdc_endpoints(device)
    eb.claim_device(device, intf, fd_wrapped=fd_wrapped)
    eb.reset_endpoint_toggles(device, ep_in, ep_out)

    bridge = eb.is_uart_bridge(device)

    if bridge:
        bring_up_bridge(device, args)
        time.sleep(0.1)
        eb.reset_endpoint_toggles(device, ep_in, ep_out)
    else:
        if eb.is_native_cdc(device):
            ctrl_iface = eb.find_cdc_control_interface(device, intf)
            eb.open_native_cdc_port(device, ctrl_iface)

    kind = "UART bridge" if bridge else "native USB CDC"
    print(f"[*] Mode: {kind}" + (f" @ {args.baud} baud" if bridge else ""), flush=True)
    print(f"[*] EP_IN=0x{ep_in:02X} EP_OUT=0x{ep_out:02X} INTF={intf}", flush=True)

    sender = eb.Sender(device, ep_out, timeout_ms=args.write_timeout_ms)
    receiver = eb.ReceiverThread(device, ep_in)
    receiver.start()

    parser = eb.FrameParser()
    stop_event = threading.Event()

    if args.send_cmd:
        send_args = {}
        if args.send_args:
            try:
                send_args = json.loads(args.send_args)
            except json.JSONDecodeError as e:
                print(f"[!] --send-args isn't valid JSON: {e}", flush=True)
        frame = eb.build_cmd(args.send_cmd, send_args)
        if sender.send_bytes(frame):
            print(f"[>>] CMD {args.send_cmd} {json.dumps(send_args)}", flush=True)
        else:
            print("[!] --send-cmd failed to send", flush=True)

    if not args.no_input:
        t = threading.Thread(target=input_writer, args=(sender, stop_event), daemon=True)
        t.start()
    else:
        print("[*] Monitoring (read-only)... Ctrl+C to stop.\n", flush=True)

    try:
        while True:
            raw = receiver.readline_bytes(timeout=0.1)
            if raw is None:
                continue
            for frame in parser.feed(raw):
                print_frame(frame, args)
    except KeyboardInterrupt:
        print("\n[*] Monitor stopped.", flush=True)
    finally:
        stop_event.set()
        receiver.stop()


if __name__ == "__main__":
    main()
