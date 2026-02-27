#!/bin/bash
# Vultra VPN Server - uninstall (does not remove WireGuard or wg0.conf)
# Usage: sudo ./uninstall.sh

set -e

PREFIX=/opt/vultra-vpn-server
SYSTEMD_UNIT_DIR=/lib/systemd/system
DEFAULT_ENV=/etc/default/vultra-vpn-server
SERVICE_NAME=vultra-vpn-server
TARGET=wrapper_server

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (e.g. sudo $0)" >&2
    exit 1
fi

echo "Stopping and disabling $SERVICE_NAME..."
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

echo "Removing systemd unit and binary..."
rm -f "$SYSTEMD_UNIT_DIR/${SERVICE_NAME}.service"
systemctl daemon-reload

rm -f "$PREFIX/$TARGET" "$PREFIX/README.md"
rmdir "$PREFIX" 2>/dev/null || true

echo "Uninstall complete."
echo "Config $DEFAULT_ENV was left in place; remove manually if desired."
echo "WireGuard and /etc/wireguard/wg0.conf were not removed; delete them manually if you no longer need the shared peer."
