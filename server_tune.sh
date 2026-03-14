#!/usr/bin/env bash
set -euo pipefail

############################################################
# 1. Kernel network tuning (sysctl)
############################################################

SYSCTL_FILE=/etc/sysctl.d/99-vultra-vpn-tuning.conf

sudo tee "$SYSCTL_FILE" >/dev/null <<'EOF'
# === Socket buffers (affects UDP/WireGuard) ===
# Allow large receive/send buffers so wrapper_server and WireGuard
# can request up to 4MB without being capped too low.
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# UDP memory limits (min, pressure, max pages)
net.ipv4.udp_mem = 4096 87380 16777216

# === NIC queue and packet processing budget ===
# Higher backlog and budget reduce drops under load.
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 8192
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000

# === IP forwarding for WireGuard tunnel traffic ===
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

echo "[*] Applying sysctl tuning from $SYSCTL_FILE"
sudo sysctl --system

############################################################
# 2. Queue discipline and txqueuelen on WireGuard/external NIC
############################################################

# Attach fq qdisc to wg0 (instead of default noqueue) to smooth bursts, and
# increase txqueuelen so the kernel can buffer more packets under load.
if ip link show wg0 >/dev/null 2>&1; then
  echo "[*] Setting fq qdisc and txqueuelen on wg0"
  sudo tc qdisc replace dev wg0 root fq
  sudo ip link set dev wg0 txqueuelen 10000
else
  echo "[!] wg0 interface not found. Run 'wg-quick up wg0' and rerun this script."
fi

# Also raise txqueuelen on the external interface if present, to reduce drops
# between the VPS and the internet.
WAN_IF=enp6s0
if ip link show "$WAN_IF" >/dev/null 2>&1; then
  echo "[*] Setting txqueuelen on $WAN_IF"
  sudo ip link set dev "$WAN_IF" txqueuelen 10000
else
  echo "[!] External interface $WAN_IF not found; skipping txqueuelen tuning."
fi

############################################################
# 3. NAT / FORWARD rules (if not already present)
############################################################

echo "[*] Ensuring basic MASQUERADE + FORWARD rules for WireGuard"

# Outbound NAT
sudo iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

# Forward wg0 -> WAN
sudo iptables -C FORWARD -i wg0 -o "$WAN_IF" -j ACCEPT 2>/dev/null \
  || sudo iptables -A FORWARD -i wg0 -o "$WAN_IF" -j ACCEPT

# Forward WAN -> wg0 for established connections
sudo iptables -C FORWARD -i "$WAN_IF" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || sudo iptables -A FORWARD -i "$WAN_IF" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

############################################################
# 4. TCP MSS clamp for WireGuard tunnel (avoid PMTU issues)
############################################################

echo "[*] Ensuring TCPMSS clamp on wg0 FORWARD traffic"

# Clamp MSS for traffic leaving wg0
sudo iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || sudo iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Clamp MSS for traffic entering wg0
sudo iptables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || sudo iptables -t mangle -A FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "[*] Done."
echo "    - sysctl settings are persistent across reboots."
echo "    - tc and iptables rules are active now; for persistence, add them"
echo "      to your boot scripts or WireGuard PostUp/PostDown hooks as needed."