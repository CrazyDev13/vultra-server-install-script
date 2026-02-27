#!/bin/bash
# Vultra VPN Server - full install (WireGuard + wrapper server + systemd service)
# Free/shared version: installs a single shared WireGuard peer that all clients use.
# Requires root. Usage: sudo ./install.sh
# For Ubuntu 24.04 / Debian. Run from the server directory.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Installing WireGuard ==="
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y wireguard
    echo "WireGuard installed."
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools 2>/dev/null || true
    echo "WireGuard tools installed (or already present)."
else
    echo "Warning: Could not detect package manager (apt/dnf). Install WireGuard manually if needed."
fi

echo ""
echo "=== Enable IP forwarding ==="
if [ -f /proc/sys/net/ipv4/ip_forward ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward
    mkdir -p /etc/sysctl.d
    if ! grep -q 'net.ipv4.ip_forward' /etc/sysctl.d/99-vultra-wg-forward.conf 2>/dev/null; then
        echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-vultra-wg-forward.conf
        echo "Created /etc/sysctl.d/99-vultra-wg-forward.conf"
    fi
    sysctl -p /etc/sysctl.d/99-vultra-wg-forward.conf 2>/dev/null || true
    echo "IP forwarding enabled (persistent)."
else
    echo "Warning: /proc/sys/net/ipv4/ip_forward not found; skipping."
fi

# Default egress interface for iptables NAT and UFW (traffic from VPN goes out here)
EGRESS_IF="$(ip -o route show default 2>/dev/null | awk '{print $5}' | head -1)"
[ -z "$EGRESS_IF" ] && EGRESS_IF="eth0"
echo "Using egress interface for NAT/forwarding: $EGRESS_IF"

WG_CONF=/etc/wireguard/wg0.conf
# Allow overriding WG_PORT via env (e.g. when called from premium admin)
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET=10.10.0.1/24
# Map VULTRA_* keys (from premium verify admin) to the keys this script expects.
if [ -z "$WG_SERVER_PRIVATE_KEY" ] && [ -n "$VULTRA_WG_SERVER_PRIVATE_KEY" ]; then
    WG_SERVER_PRIVATE_KEY="$VULTRA_WG_SERVER_PRIVATE_KEY"
fi
if [ -z "$WG_APP_CLIENT_PRIVATE_KEY" ] && [ -n "$VULTRA_WG_CLIENT_PRIVATE_KEY" ]; then
    WG_APP_CLIENT_PRIVATE_KEY="$VULTRA_WG_CLIENT_PRIVATE_KEY"
fi
# App client private key: use from env when set (dashboard Install), else fallback for manual runs.
# Must match "WireGuard client private key" in admin Settings (used for .vultra configs).
if [ -n "$WG_APP_CLIENT_PRIVATE_KEY" ]; then
    APP_CLIENT_PRIVATE_KEY="$WG_APP_CLIENT_PRIVATE_KEY"
else
    APP_CLIENT_PRIVATE_KEY="mJZTH+uMWHHwQuXEEM865m1QEM7+t1a+tKuwlc+uWXk="
fi

echo ""
echo "=== Creating WireGuard config ==="
install -d /etc/wireguard
chmod 700 /etc/wireguard

if [ -f "$WG_CONF" ]; then
    echo "WireGuard config $WG_CONF already exists; skipping."
else
    if ! command -v wg >/dev/null 2>&1; then
        echo "Error: wg not found. Install wireguard-tools first." >&2
        exit 1
    fi
    # Use same server key across wrapper servers when provided (e.g. from dashboard Install)
    if [ -n "$WG_SERVER_PRIVATE_KEY" ]; then
        SERVER_PRIVATE="$WG_SERVER_PRIVATE_KEY"
        echo "Using provided WireGuard server private key (same key across wrapper servers)."
    else
        SERVER_PRIVATE=$(wg genkey)
    fi
    SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | wg pubkey)
    CLIENT_PUBLIC=$(echo "$APP_CLIENT_PRIVATE_KEY" | wg pubkey)

    # PostUp/PostDown: iptables FORWARD and NAT MASQUERADE so VPN clients can reach the internet
    cat > "$WG_CONF" << EOF
# Vultra VPN Server - WireGuard (created by install.sh)
# Wrapper server forwards to 127.0.0.1:$WG_PORT; start WG with: wg-quick up wg0

[Interface]
PrivateKey = $SERVER_PRIVATE
Address = $WG_SUBNET
ListenPort = $WG_PORT
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $EGRESS_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $EGRESS_IF -j MASQUERADE

[Peer]
# Default Android app client (free/shared peer; all clients use this)
PublicKey = $CLIENT_PUBLIC
AllowedIPs = 10.10.0.2/32
EOF
    chmod 600 "$WG_CONF"
    echo "Created $WG_CONF"
    echo ""
    echo "  Server public key:"
    echo "  $SERVER_PUBLIC"
    echo "  Make sure the Android app's WireGuard peer PublicKey matches this (or rebuild the app with this key)."
    echo ""
fi

echo ""
echo "=== Firewall (UFW) ==="
if command -v ufw >/dev/null 2>&1; then
    # Allow WireGuard port
    ufw allow "$WG_PORT/udp" 2>/dev/null || true
    # Ensure IP forwarding is enabled in UFW's sysctl (for when UFW is active)
    if [ -f /etc/ufw/sysctl.conf ]; then
        if grep -q '^#*net/ipv4/ip_forward' /etc/ufw/sysctl.conf; then
            sed -i 's/^#*net\/ipv4\/ip_forward=.*/net\/ipv4\/ip_forward=1/' /etc/ufw/sysctl.conf
        else
            echo "net/ipv4/ip_forward=1" >> /etc/ufw/sysctl.conf
        fi
        echo "Set net/ipv4/ip_forward=1 in /etc/ufw/sysctl.conf"
    fi
    # Allow forwarding from wg0 to egress (so VPN clients can reach internet when UFW is enabled)
    ufw route allow in on wg0 out on "$EGRESS_IF" 2>/dev/null || true
    echo "UFW rules added: $WG_PORT/udp, forward wg0 -> $EGRESS_IF. Run 'ufw enable' if you use UFW."
else
    echo "UFW not found; skipping UFW rules. Use iptables or your firewall as needed."
fi

echo ""
echo "=== Preparing wrapper_server binary ==="
if [ ! -x "$TARGET" ]; then
    # If a non-executable file exists, try to make it executable
    if [ -f "$TARGET" ]; then
        chmod +x "$TARGET" || true
    fi
fi

if [ ! -x "$TARGET" ]; then
    echo "Error: prebuilt $TARGET binary not found or not executable in $SCRIPT_DIR." >&2
    echo "Build it separately from wrapper_server.c (e.g. with 'make') and then re-run install.sh." >&2
    exit 1
fi

echo ""
echo "=== Installing Vultra VPN Server ==="
install -d "$PREFIX"
# When running from inside PREFIX (e.g. repo cloned at /opt/vultra-vpn-server), avoid "same file" error
REAL_SCRIPT="$(cd "$SCRIPT_DIR" && pwd -P)"
REAL_PREFIX="$(cd "$PREFIX" && pwd -P)"
if [ "$REAL_SCRIPT" = "$REAL_PREFIX" ]; then
    chmod 755 "$TARGET" 2>/dev/null || true
else
    install -m 755 "$TARGET" "$PREFIX/"
fi
# Allow binding to privileged ports (e.g. 78) when run as vultra-vpn
if command -v setcap >/dev/null 2>&1; then
    setcap 'cap_net_bind_service=+ep' "$PREFIX/$TARGET" || true
    echo "Set cap_net_bind_service on $PREFIX/$TARGET"
else
    echo "Warning: setcap not found (install libcap2-bin). Service may fail to bind port < 1024."
fi
if [ "$REAL_SCRIPT" = "$REAL_PREFIX" ]; then
    chmod 644 README.md PREMIUM_VERIFY_API.md 2>/dev/null || true
else
    install -m 644 README.md "$PREFIX/" 2>/dev/null || true
    install -m 644 PREMIUM_VERIFY_API.md "$PREFIX/" 2>/dev/null || true
fi
echo "Binary and docs installed to $PREFIX/"

install -d "$SYSTEMD_UNIT_DIR"
install -m 644 wrapper_server.service "$SYSTEMD_UNIT_DIR/${SERVICE_NAME}.service"
echo "Systemd unit installed: ${SERVICE_NAME}.service"
echo ""
echo "=== Wrapper env: $DEFAULT_ENV ==="
# If wrapper/server or premium parameters are provided via environment, generate
# the env file automatically. Otherwise, fall back to the example file.
AUTO_ENV_INPUT="${WRAPPER_SERVER}${WRAPPER_BASE_PORT}${WRAPPER_NUM_PORTS}${WG_SERVER}${WG_PORT}${WRAPPER_KEY_HEX}${WRAPPER_SERVER_MODE}${PREMIUM_VERIFY_PUBLIC_URL}${PREMIUM_VERIFY_API_KEY}"
if [ -n "$AUTO_ENV_INPUT" ]; then
    echo "Writing $DEFAULT_ENV from provided environment parameters."
    WRAPPER_SERVER_VALUE="${WRAPPER_SERVER:-your-server.example.com}"
    BASE_PORT_VALUE="${WRAPPER_BASE_PORT:-78}"
    NUM_PORTS_VALUE="${WRAPPER_NUM_PORTS:-100}"
    WG_SERVER_VALUE="${WG_SERVER:-127.0.0.1}"
    WG_PORT_VALUE="${WG_PORT:-51820}"
    VERIFY_URL=""
    if [ -n "$PREMIUM_VERIFY_PUBLIC_URL" ]; then
        VERIFY_BASE="${PREMIUM_VERIFY_PUBLIC_URL%/}"
        VERIFY_URL="${VERIFY_BASE}/verify"
    fi
    umask 027
    cat > "$DEFAULT_ENV" << EOF
# Auto-generated by install.sh
WRAPPER_SERVER=$WRAPPER_SERVER_VALUE
WRAPPER_BASE_PORT=$BASE_PORT_VALUE
WRAPPER_NUM_PORTS=$NUM_PORTS_VALUE
WG_SERVER=$WG_SERVER_VALUE
WG_PORT=$WG_PORT_VALUE
EOF
    if [ -n "$WRAPPER_KEY_HEX" ]; then
        echo "WRAPPER_KEY_HEX=$WRAPPER_KEY_HEX" >> "$DEFAULT_ENV"
    fi
    if [ -n "$WRAPPER_SERVER_MODE" ]; then
        echo "WRAPPER_SERVER_MODE=$WRAPPER_SERVER_MODE" >> "$DEFAULT_ENV"
    elif [ -n "$VERIFY_URL" ]; then
        echo "WRAPPER_SERVER_MODE=premium" >> "$DEFAULT_ENV"
    fi
    if [ -n "$VERIFY_URL" ]; then
        echo "PREMIUM_VERIFY_URL=$VERIFY_URL" >> "$DEFAULT_ENV"
    fi
    if [ -n "$PREMIUM_VERIFY_API_KEY" ]; then
        echo "PREMIUM_VERIFY_API_KEY=$PREMIUM_VERIFY_API_KEY" >> "$DEFAULT_ENV"
    fi
    chmod 640 "$DEFAULT_ENV"
else
    if [ ! -f "$DEFAULT_ENV" ]; then
        install -m 640 wrapper_server.env.example "$DEFAULT_ENV"
        echo "Created $DEFAULT_ENV from example - EDIT IT with your key and WG server."
    else
        echo "Keeping existing $DEFAULT_ENV"
    fi
fi

if ! id -u vultra-vpn >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin vultra-vpn
    echo "Created user vultra-vpn"
else
    echo "User vultra-vpn already exists"
fi

systemctl daemon-reload
echo ""
echo "=== Install complete ==="
echo "1. WireGuard: config is $WG_CONF (with iptables NAT/forward via PostUp/PostDown)"
echo "   IP forwarding: enabled (net.ipv4.ip_forward=1, persistent in /etc/sysctl.d/)"
echo "   Start WireGuard: wg-quick up wg0"
echo "   Enable at boot (optional): systemctl enable wg-quick@wg0"
if [ ! -f "$WG_CONF" ]; then
    echo "   (Config was not created; create it manually or re-run install.)"
else
    echo "   In the free/shared version, all clients use the same WireGuard peer (10.10.0.2/32)."
    echo "   If you deploy multiple servers, you may copy this wg0.conf to each node."
fi
echo "2. Edit Vultra VPN wrapper config: nano $DEFAULT_ENV"
echo "   Set WRAPPER_KEY_HEX, WG_SERVER=127.0.0.1, WG_PORT=$WG_PORT, and ports."
echo "   For free server: leave PREMIUM_VERIFY_URL unset (or set WRAPPER_SERVER_MODE=free)."
echo "   For premium-only server: set WRAPPER_SERVER_MODE=premium and PREMIUM_VERIFY_URL. See $PREFIX/PREMIUM_VERIFY_API.md"
echo "3. Enable and start: systemctl enable --now $SERVICE_NAME"
echo "4. Logs: journalctl -u $SERVICE_NAME -f"
echo ""
