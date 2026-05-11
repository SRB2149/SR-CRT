#!/bin/bash
#
# setup_pi.sh - one-shot setup for the v4l2-to-spi CRT bridge
#
# Does everything: package install, SPI enable, spidev buffer config,
# group membership, build the binary, install the systemd service.
# Optionally enables the read-only overlay at the end.
#
# Run as your normal user. Don't sudo this; it sudos where needed.

set -euo pipefail

# Which C file to build. Switch to v4l2_to_spi.c if you prefer Bayer dither.
SOURCE_FILE="v4l2_to_spi_atkinson.c"
BINARY_NAME="v4l2_to_spi"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }

if [[ $EUID -eq 0 ]]; then
    err "Don't run this as root. Run as your normal user; sudo is used internally."
    exit 1
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
    err "$SOURCE_FILE not found in current directory."
    err "scp it over from your laptop and run this script from the same directory."
    exit 1
fi

# ----------------------------------------------------------------------
# 1. System update and packages
# ----------------------------------------------------------------------
log "Updating package lists..."
sudo apt update

log "Upgrading installed packages (this can take a few minutes)..."
sudo apt full-upgrade -y

log "Installing build tools and V4L2 utilities..."
sudo apt install -y \
    build-essential \
    v4l-utils \
    git \
    tmux \
    htop \
    ffmpeg \
    libjpeg62-turbo-dev \
    libjpeg-turbo-progs

# ----------------------------------------------------------------------
# 2. Enable SPI
# ----------------------------------------------------------------------
log "Enabling SPI interface..."
sudo raspi-config nonint do_spi 0

# ----------------------------------------------------------------------
# 3. Bump spidev buffer size
# ----------------------------------------------------------------------
CMDLINE=/boot/firmware/cmdline.txt
if [[ ! -f "$CMDLINE" ]]; then
    CMDLINE=/boot/cmdline.txt
fi

if [[ ! -f "$CMDLINE" ]]; then
    err "Could not find cmdline.txt"
    exit 1
fi

if grep -q "spidev.bufsiz=" "$CMDLINE"; then
    log "spidev.bufsiz already set in $CMDLINE - leaving it alone."
else
    log "Adding spidev.bufsiz=65536 to $CMDLINE..."
    # cmdline.txt must be a single line with space-separated arguments.
    # Strip any trailing newline/whitespace, then append with a leading space.
    CURRENT=$(tr -d '\n' < "$CMDLINE" | sed 's/[[:space:]]*$//')
    echo "$CURRENT spidev.bufsiz=65536" | sudo tee "$CMDLINE" > /dev/null
fi

# ----------------------------------------------------------------------
# 4. Group membership
# ----------------------------------------------------------------------
log "Adding $USER to video, spi, gpio groups..."
sudo usermod -a -G video,spi,gpio "$USER"

# ----------------------------------------------------------------------
# 5. Disable triggerhappy and swap
# ----------------------------------------------------------------------
if systemctl list-unit-files | grep -q '^triggerhappy.service'; then
    log "Disabling triggerhappy.service..."
    sudo systemctl disable --now triggerhappy.service || true
fi

if systemctl is-enabled --quiet dphys-swapfile 2>/dev/null; then
    log "Disabling swap..."
    sudo dphys-swapfile swapoff || true
    sudo systemctl disable dphys-swapfile || true
fi

# ----------------------------------------------------------------------
# 6. Build the binary
# ----------------------------------------------------------------------
log "Building $BINARY_NAME from $SOURCE_FILE..."
gcc -O3 -march=armv8-a -mtune=cortex-a53 -Wall -Wextra \
    -o "$BINARY_NAME" "$SOURCE_FILE"

INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
log "Installing to $INSTALL_PATH..."
sudo install -m 755 "$BINARY_NAME" "$INSTALL_PATH"

# ----------------------------------------------------------------------
# 7. systemd service
# ----------------------------------------------------------------------
log "Installing systemd service..."

sudo tee /etc/systemd/system/v4l2-to-spi.service > /dev/null <<EOF
[Unit]
Description=V4L2 to SPI capture-to-CRT bridge
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH
ExecStartPre=/bin/sleep 5
Restart=always
RestartSec=2
User=$USER
Group=$USER
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable v4l2-to-spi.service

# ----------------------------------------------------------------------
# 8. Optional: read-only overlay
# ----------------------------------------------------------------------
echo
warn "Read-only root overlay protects the SD card from corruption on power loss."
warn "Once enabled, you'll need to disable it temporarily to change anything."
echo
read -rp "Enable read-only overlay? [y/N] " enable_overlay

if [[ "$enable_overlay" =~ ^[Yy]$ ]]; then
    log "Enabling read-only overlay..."
    sudo raspi-config nonint enable_overlayfs
    sudo raspi-config nonint enable_bootro
    warn "Overlay enabled. The SD card will be read-only after the next reboot."
fi

# ----------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------
echo
log "Setup complete."
echo
echo "Reboot now with: sudo reboot"
echo
echo "After reboot the service will start automatically. Check it with:"
echo "    sudo systemctl status v4l2-to-spi"
echo "    journalctl -u v4l2-to-spi -f"
echo