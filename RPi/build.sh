#!/bin/bash
#
# build.sh - rebuild the v4l2-to-spi binary and reinstall it
#
# Use after editing the C source. Disables the service, rebuilds,
# reinstalls, and restarts. You'll need read-write rootfs first
# (sudo raspi-config -> Performance Options -> Overlay FS -> No, reboot).

set -euo pipefail

SOURCE_FILE="v4l2_to_spi_atkinson.c"   # or v4l2_to_spi.c for Bayer
BINARY_NAME="v4l2_to_spi"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"

echo "Building $BINARY_NAME from $SOURCE_FILE..."
gcc -O3 -march=armv8-a -mtune=cortex-a53 -Wall -Wextra \
    -o "$BINARY_NAME" "$SOURCE_FILE"

echo "Stopping service..."
sudo systemctl stop v4l2-to-spi.service || true

echo "Installing to $INSTALL_PATH..."
sudo install -m 755 "$BINARY_NAME" "$INSTALL_PATH"

echo "Starting service..."
sudo systemctl start v4l2-to-spi.service

echo "Done. Check status with: sudo systemctl status v4l2-to-spi"
