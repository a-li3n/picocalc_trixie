# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides a Debian Trixie (32-bit Lite) setup guide and Linux kernel drivers for the **PicoCalc** — a handheld device running a Raspberry Pi Zero 2 with a 320x320 SPI display and I2C keyboard.

There is no build system at the repository root. All commands must be run **on the target Raspberry Pi Zero 2** (or a cross-compile environment with matching kernel headers).

## Key Hardware

- **Display**: 320x320 SPI panel driven by `mipi-dbi-spi` kernel overlay. Initialized via `picomipi.bin` (compiled from `picomipi.txt`).
- **Keyboard**: PicoCalc keyboard controller at I2C address `0x1f` on I2C-1 (GPIO2/3). Registers: `0x05` backlight, `0x09` key FIFO, `0x0A` backlight2, `0x0B` battery.
- **Audio**: PWM audio remapped to GPIO 12/13 via `audremap` overlay.
- **Power-off**: STM32 on the keyboard controller handles shutdown via `i2cset -yf 1 0x1f 0x8e 0x00`.

## Building the Keyboard Driver

Must be run on the Pi with kernel headers installed. The module is managed by DKMS (`picocalc_kbd/dkms.conf`, version 1.0), so it rebuilds automatically after kernel updates.

The kernel headers package name varies by OS variant — `install.sh` auto-detects it. Candidates in priority order: `raspberrypi-kernel-headers` (32-bit RPi OS), `linux-headers-rpi-v8` (64-bit RPi OS on Pi Zero 2 W / Pi 4), `linux-headers-rpi-2712` (Pi 5), `linux-headers-$(uname -r)` (plain Debian fallback).

To build manually (outside of install.sh / DKMS):

```bash
cd picocalc_kbd
make          # builds picocalc_kbd.ko against running kernel
make clean
```

DKMS source lives at `/usr/src/picocalc_kbd-1.0/` after install. To force a DKMS rebuild:

```bash
sudo dkms build picocalc_kbd/1.0
sudo dkms install picocalc_kbd/1.0
```

The DTS overlay is compiled from source during install. To recompile manually:

```bash
dtc -@ -I dts -O dtb -W no-unit_address_vs_reg \
    -o /boot/firmware/overlays/picocalc_kbd.dtbo \
    picocalc_kbd/dts/picocalc_kbd-overlay.dts
```

## Display Firmware

`picomipi.bin` is compiled from `picomipi.txt` using the `panel-mipi-dbi/mipi-dbi-cmd` Python script:

```bash
# Compile .txt → .bin
python3 panel-mipi-dbi/mipi-dbi-cmd picomipi.bin picomipi.txt

# Decompile .bin → .txt (inspect current binary)
python3 panel-mipi-dbi/mipi-dbi-cmd picomipi.bin
```

## Full Installation

Run `install.sh` from the repo root on the Pi (requires root). This is the comprehensive single-pass installer that covers everything in the README:

```bash
sudo ./install.sh
sudo reboot
```

`setup_keyboard.sh` is the original partial script (keyboard only, has known bugs — see below). Prefer `install.sh`.

## Kernel Driver Architecture (`picocalc_kbd/`)

- **`picocalc_kbd.c`**: I2C client driver registered for compatible string `picocalc_kbd`. Uses a work queue (`work_struct`) to handle keyboard interrupts. Reads a 31-entry FIFO from the keyboard controller (reg `0x09`) on each interrupt. Supports mouse emulation mode (toggled by a key combo), reading directional bits from the FIFO item's state field. Exposes battery percent and backlight via `/sys/firmware/picocalc/`.
- **`picocalc_kbd_code.h`**: Mapping from keyboard controller scancodes to Linux HID keycodes.
- **`debug_levels.h`**: Debug verbosity macros (`DEBUG_LEVEL_OFF/FE/RW/LD`). Default is `DEBUG_LEVEL_OFF`. To enable debug output, edit this file and rebuild; view with `dmesg -wH | grep picocalc`.
- **`dts/picocalc_kbd-overlay.dts`**: Device tree overlay binding the keyboard to I2C-1 at address `0x1f`.

## Scripts (deployed to user home during install)

```
scripts/
  README          → ~/README          home quick-reference card
  ai/             → ~/ai/             Claude AI tools
    llm             wrapper for venv llm binary
    ask             one-shot query; pipe-aware; "ask setup" for first-time config
    chat            interactive session (wraps llm chat)
    explain         explain a source file, tuned for small screen output
    commit-msg      generate commit subject from git diff --staged
  dev/            → ~/dev/            system helpers
    battery         show charge level; --tmux flag for compact status-bar format
    bright          read/set backlight via i2c (0-255, supports +N/-N)
    s               ripgrep wrapper with color disabled (framebuffer-safe)
    note            append-only scratch pad to ~/notes.md; opens nvim with no args
    serve           python3 http.server wrapper that prints the device IP
  gaming/         → ~/gaming/         game launchers
    picocalc-run    SDL2 wrapper (sets SDL_VIDEODRIVER=fbdev, SDL_FBDEV=/dev/fb1)
    pico8           PICO-8 launcher; auto-selects pico8_64 vs pico8
    pyg             pygame script launcher; also unsets DISPLAY to prevent X11 fallback
```

All scripts are also symlinked into `~/bin/` so they're on PATH. `~/bin` is added to PATH by the default Debian `.profile` when it exists.

## Post-Install User Setup (after reboot)

```bash
cat ~/README         # quick reference card
ask setup            # configure Claude API key (one time)
ask "question"       # one-shot Claude query
cat file.py | ask    # pipe to Claude
chat                 # interactive session
explain file.py      # explain source code

FRAMEBUFFER=/dev/fb1 fbterm  # better terminal (Terminus font installed)
```

## Boot Configuration Files

- **`config.txt`**: Reference `/boot/firmware/config.txt` — enables SPI, I2C, MIPI-DBI display overlay, keyboard overlay, audio remap.
- **`picomipi.txt`**: Human-readable ILI9341-style init command sequence for the display.
- **`picomipi.bin`**: Binary firmware consumed by the `panel-mipi-dbi` kernel driver from `/lib/firmware/picomipi.bin`.
