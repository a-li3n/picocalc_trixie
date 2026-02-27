#!/bin/bash
# PicoCalc Trixie Full Installer
# Run from the repo root on your Pi Zero 2: sudo ./install.sh
#
# Covers: display, keyboard (DKMS), audio, power-off,
#         portable dev tools, AI terminal (llm + Claude),
#         and retro gaming (SDL2, pygame, PICO-8 launcher).
#
# Safe to re-run; all steps are idempotent.

set -euo pipefail

# ── Sanity checks ────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must be run as root. Use: sudo ./install.sh"
    exit 1
fi

if [ ! -f "/boot/firmware/config.txt" ]; then
    echo "ERROR: /boot/firmware/config.txt not found."
    echo "       This script expects Raspberry Pi OS Trixie."
    exit 1
fi

REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ]; then
    echo "ERROR: Could not determine the non-root user."
    echo "       Use sudo rather than logging in directly as root."
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
KERNEL_VER="$(uname -r)"
ARCH="$(uname -m)"

BOOT_CONFIG="/boot/firmware/config.txt"
BOOT_CMDLINE="/boot/firmware/cmdline.txt"
BOOT_OVERLAYS="/boot/firmware/overlays"
FIRMWARE_DIR="/lib/firmware"
MODULE_NAME="picocalc_kbd"
MODULE_VER="1.0"
DKMS_SRC="/usr/src/${MODULE_NAME}-${MODULE_VER}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PicoCalc Trixie Installer"
echo "  User:   ${REAL_USER} (${USER_HOME})"
echo "  Kernel: ${KERNEL_VER}  Arch: ${ARCH}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Configure apt ────────────────────────────────────────────────────

echo "[1/11] Configuring apt..."
cat > /etc/apt/apt.conf.d/99local <<'EOF'
APT::Install-Suggests "false";
APT::Install-Recommends "false";
EOF

# ── Step 2: Install all packages up front ────────────────────────────────────

echo "[2/11] Installing packages (this may take a while)..."
apt-get update -q

# Detect kernel headers package — name differs between 32-bit and 64-bit
# Raspberry Pi OS and plain Debian Trixie.
detect_headers_pkg() {
    local candidates=(
        raspberrypi-kernel-headers   # 32-bit Raspberry Pi OS
        linux-headers-rpi-v8         # 64-bit Raspberry Pi OS (Pi 2/3/4/Zero2W)
        linux-headers-rpi-2712       # 64-bit Raspberry Pi OS (Pi 5)
        "linux-headers-$(uname -r)"  # plain Debian / fallback
    )
    for pkg in "${candidates[@]}"; do
        if apt-cache show "$pkg" &>/dev/null 2>&1; then
            echo "$pkg"
            return
        fi
    done
    echo ""
}
HEADERS_PKG="$(detect_headers_pkg)"
if [ -z "$HEADERS_PKG" ]; then
    echo "ERROR: Could not find a kernel headers package." >&2
    echo "       Run: apt-cache search linux-headers" >&2
    exit 1
fi
echo "      Using kernel headers package: ${HEADERS_PKG}"

apt-get install -y \
    `# Kernel module build` \
    build-essential \
    "${HEADERS_PKG}" \
    device-tree-compiler \
    dkms \
    `# Hardware access` \
    i2c-tools \
    `# Terminal / display` \
    fbterm \
    fonts-terminus \
    tmux \
    `# Portable dev` \
    neovim \
    git \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    fd-find \
    curl \
    man-db \
    `# Retro gaming / SDL2` \
    libsdl2-2.0-0 \
    libsdl2-image-2.0-0 \
    libsdl2-mixer-2.0-0 \
    libsdl2-ttf-2.0-0 \
    libgles2 \
    libegl-dev \
    python3-pygame

# Users need video group membership for fbterm and /dev/fb* access
usermod -aG video "$REAL_USER"

# ── Step 3: Display firmware ─────────────────────────────────────────────────

echo "[3/11] Installing display firmware..."
cp "${REPO_DIR}/picomipi.bin" "${FIRMWARE_DIR}/"

# ── Step 4: Keyboard module via DKMS ─────────────────────────────────────────
# DKMS rebuilds the module automatically after kernel updates.

echo "[4/11] Registering keyboard module with DKMS..."
dkms remove "${MODULE_NAME}/${MODULE_VER}" --all 2>/dev/null || true
rm -rf "${DKMS_SRC}"
cp -r "${REPO_DIR}/${MODULE_NAME}" "${DKMS_SRC}"
dkms add     "${MODULE_NAME}/${MODULE_VER}"
dkms build   "${MODULE_NAME}/${MODULE_VER}" -k "${KERNEL_VER}"
dkms install "${MODULE_NAME}/${MODULE_VER}" -k "${KERNEL_VER}"

# ── Step 5: Device tree overlay ──────────────────────────────────────────────

echo "[5/11] Compiling and installing device tree overlay..."
dtc -@ -I dts -O dtb \
    -W no-unit_address_vs_reg \
    -o "${BOOT_OVERLAYS}/${MODULE_NAME}.dtbo" \
    "${REPO_DIR}/${MODULE_NAME}/dts/${MODULE_NAME}-overlay.dts"

# ── Step 6: Patch /boot/firmware/config.txt ──────────────────────────────────

echo "[6/11] Patching boot config..."

# Enable SPI
if grep -q "^#dtparam=spi=on" "${BOOT_CONFIG}"; then
    sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "${BOOT_CONFIG}"
elif ! grep -q "^dtparam=spi=on" "${BOOT_CONFIG}"; then
    echo "dtparam=spi=on" >> "${BOOT_CONFIG}"
fi

# Display overlay
if ! grep -q "mipi-dbi-spi" "${BOOT_CONFIG}"; then
    cat >> "${BOOT_CONFIG}" <<'EOF'

# PicoCalc Display (320x320 SPI, ILI9341-compatible)
dtoverlay=mipi-dbi-spi,spi0-0,speed=70000000
dtparam=compatible=picomipi\0panel-mipi-dbi-spi
dtparam=width=320,height=320,width-mm=43,height-mm=43
dtparam=reset-gpio=25,dc-gpio=24
dtparam=backlight-gpio=18
dtparam=clock-frequency=50
EOF
fi

# Keyboard overlay
if ! grep -q "dtoverlay=picocalc_kbd" "${BOOT_CONFIG}"; then
    cat >> "${BOOT_CONFIG}" <<'EOF'

# PicoCalc Keyboard (I2C-1, address 0x1f)
dtparam=i2c_arm=on
dtoverlay=picocalc_kbd
EOF
fi

# Audio remap to GPIO 12/13
if ! grep -q "audremap" "${BOOT_CONFIG}"; then
    sed -i '/^dtparam=audio=on/a dtoverlay=audremap,pins_12_13' "${BOOT_CONFIG}"
fi

# ── Step 7: Patch /boot/firmware/cmdline.txt ─────────────────────────────────

echo "[7/11] Patching boot cmdline..."
# Must remain a single line; MINI4x6 gives ~80x53 on the 320x320 display
if ! grep -q "fbcon=map:1" "${BOOT_CMDLINE}"; then
    sed -i 's/$/ fbcon=map:1 fbcon=font:MINI4x6/' "${BOOT_CMDLINE}"
fi

# ── Step 8: Power-off service ─────────────────────────────────────────────────

echo "[8/11] Setting up power-off service..."

cat > /usr/local/bin/picopoweroff <<'EOF'
#!/bin/sh
# Signal the STM32 keyboard controller to cut board power
i2cset -yf 1 0x1f 0x8e 0x00
EOF
chmod +x /usr/local/bin/picopoweroff

cat > /usr/lib/systemd/system/picopoweroff.service <<'EOF'
[Unit]
Description=Shut down PicoCalc via keyboard controller
Conflicts=reboot.target
DefaultDependencies=no
After=shutdown.target
Requires=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/bin/picopoweroff

[Install]
WantedBy=shutdown.target
EOF
systemctl daemon-reload
systemctl enable picopoweroff

# ── Step 9: AI venv ───────────────────────────────────────────────────────────
# Install llm + Claude plugin into a dedicated venv so pip doesn't conflict
# with system packages. Scripts in scripts/ai/ wrap this venv.

echo "[9/11] Setting up AI venv (llm + Claude plugin)..."
AI_ENV="${USER_HOME}/.ai-env"
sudo -u "$REAL_USER" python3 -m venv "${AI_ENV}"
sudo -u "$REAL_USER" "${AI_ENV}/bin/pip" install -q --upgrade pip
sudo -u "$REAL_USER" "${AI_ENV}/bin/pip" install -q llm llm-claude-3

# ── Step 10: Deploy scripts ───────────────────────────────────────────────────
# Copies ai/, dev/, gaming/ from scripts/ to the user's home directory.
# Creates symlinks in ~/bin/ so all commands are on PATH.

echo "[10/11] Deploying scripts..."

SCRIPTS_SRC="${REPO_DIR}/scripts"
mkdir -p "${USER_HOME}/bin" "${USER_HOME}/games"

# Deploy each scenario folder
for FOLDER in ai dev gaming; do
    DEST="${USER_HOME}/${FOLDER}"
    rm -rf "${DEST}"
    cp -r "${SCRIPTS_SRC}/${FOLDER}" "${DEST}"
    chmod +x "${DEST}"/*  # make all files executable; README is harmless
done

# Copy the home README
cp "${SCRIPTS_SRC}/README" "${USER_HOME}/README"

# Symlink everything from each folder into ~/bin/ (skip README files)
for FOLDER in ai dev gaming; do
    for SCRIPT in "${USER_HOME}/${FOLDER}"/*; do
        BASENAME="$(basename "$SCRIPT")"
        [ "$BASENAME" = "README" ] && continue
        ln -sf "../${FOLDER}/${BASENAME}" "${USER_HOME}/bin/${BASENAME}"
    done
done

# ── Step 11: Config stubs ─────────────────────────────────────────────────────

echo "[11/11] Writing config stubs..."

# tmux: battery in status bar (uses battery --tmux from deployed scripts)
TMUX_CONF="${USER_HOME}/.tmux.conf"
if ! grep -q "battery" "${TMUX_CONF}" 2>/dev/null; then
    echo 'set-option -ag status-right "#[fg=red,dim,bg=default]#(~/bin/battery --tmux) "' \
        >> "${TMUX_CONF}"
fi

# Minimal Neovim config (only if not already configured)
NVIM_CONF="${USER_HOME}/.config/nvim"
if [ ! -f "${NVIM_CONF}/init.lua" ]; then
    mkdir -p "${NVIM_CONF}"
    cat > "${NVIM_CONF}/init.lua" <<'EOF'
-- Minimal PicoCalc neovim config. Replace or extend as needed.
vim.opt.number    = true
vim.opt.mouse     = ''      -- disable mouse (no trackpad)
vim.opt.wrap      = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop   = 4
EOF
fi

# Fix ownership of everything written to the user's home
chown -R "${REAL_USER}:${REAL_USER}" \
    "${USER_HOME}/ai" \
    "${USER_HOME}/dev" \
    "${USER_HOME}/gaming" \
    "${USER_HOME}/games" \
    "${USER_HOME}/bin" \
    "${USER_HOME}/README" \
    "${USER_HOME}/.ai-env" \
    "${USER_HOME}/.config" \
    "${TMUX_CONF}" 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation complete."
echo ""
echo "  1. sudo reboot"
echo ""
echo "  After reboot:"
echo "  2. cat ~/README            — quick reference"
echo "  3. ask setup               — configure Claude API key"
echo "  4. cat ~/gaming/README     — PICO-8 install instructions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
