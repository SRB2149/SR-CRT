#!/bin/bash
#
# setup_pi.sh — one-shot post-install configuration for the
# v4l2-to-spi project on Raspberry Pi OS Lite (Bookworm, 64-bit).
#
# Usage:
#   chmod +x setup_pi.sh
#   ./setup_pi.sh
#
# Run as your normal user (NOT as root). The script will sudo where needed.
# Reboot at the end to apply kernel cmdline and group changes.

set -euo pipefail

# Colours for legibility
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

# ----------------------------------------------------------------------
# 1. System update
# ----------------------------------------------------------------------
log "Updating package lists..."
sudo apt update

log "Upgrading installed packages (this can take a few minutes)..."
sudo apt full-upgrade -y

# ----------------------------------------------------------------------
# 2. Install required packages
# ----------------------------------------------------------------------
log "Installing build tools and V4L2 utilities..."
sudo apt install -y \
    build-essential \
    v4l-utils \
    git \
    tmux \
    htop \
    ffmpeg

# Optional but useful — install only if MJPEG decode might be needed later
log "Installing libjpeg-turbo (in case you ever need MJPEG decode)..."
sudo apt install -y libjpeg62-turbo-dev libjpeg-turbo-progs

# ----------------------------------------------------------------------
# 3. Enable SPI
# ----------------------------------------------------------------------
log "Enabling SPI interface..."
sudo raspi-config nonint do_spi 0

# ----------------------------------------------------------------------
# 4. Bump spidev buffer size to fit 9472-byte frames
# ----------------------------------------------------------------------
CMDLINE=/boot/firmware/cmdline.txt
if [[ ! -f "$CMDLINE" ]]; then
    # Older Raspberry Pi OS releases used /boot/cmdline.txt
    CMDLINE=/boot/cmdline.txt
fi

if [[ ! -f "$CMDLINE" ]]; then
    err "Could not find cmdline.txt at /boot/firmware/cmdline.txt or /boot/cmdline.txt"
    exit 1
fi

if grep -q "spidev.bufsiz=" "$CMDLINE"; then
    log "spidev.bufsiz is already set in $CMDLINE — leaving it alone."
else
    log "Adding spidev.bufsiz=65536 to $CMDLINE..."
    # cmdline.txt MUST be a single line. Append to the existing line, no newline.
    sudo sed -i 's/$/ spidev.bufsiz=65536/' "$CMDLINE"
fi

# ----------------------------------------------------------------------
# 5. Add user to required groups
# ----------------------------------------------------------------------
log "Adding $USER to video and spi groups..."
sudo usermod -a -G video,spi,gpio "$USER"

# ----------------------------------------------------------------------
# 6. Disable triggerhappy (useless on a headless Pi)
# ----------------------------------------------------------------------
if systemctl list-unit-files | grep -q '^triggerhappy.service'; then
    log "Disabling triggerhappy.service..."
    sudo systemctl disable --now triggerhappy.service || true
fi

# ----------------------------------------------------------------------
# 7. Disable swap (optional, reduces SD wear and crash corruption risk)
# ----------------------------------------------------------------------
if systemctl is-enabled --quiet dphys-swapfile 2>/dev/null; then
    log "Disabling swap to reduce SD card wear..."
    sudo dphys-swapfile swapoff || true
    sudo systemctl disable dphys-swapfile || true
fi

# ----------------------------------------------------------------------
# 8. Sanity checks
# ----------------------------------------------------------------------
log "Sanity-checking the install..."
echo
echo "  gcc:        $(gcc --version | head -1)"
echo "  v4l2-ctl:   $(v4l2-ctl --version)"
echo "  groups:     $(groups)"
echo "  cmdline:    $(cat "$CMDLINE")"
echo

# ----------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------
warn "REBOOT REQUIRED for SPI buffer size and group changes to take effect."
echo
echo -e "${GREEN}Setup complete.${NC} Reboot now with:"
echo
echo "    sudo reboot"
echo
echo "After reboot, verify with:"
echo
echo "    ls /dev/spidev*                         # should show /dev/spidev0.0"
echo "    cat /sys/module/spidev/parameters/bufsiz # should be 65536"
echo "    groups                                   # should include video, spi"
echo "    v4l2-ctl --list-devices                  # should show your capture card"
echo
