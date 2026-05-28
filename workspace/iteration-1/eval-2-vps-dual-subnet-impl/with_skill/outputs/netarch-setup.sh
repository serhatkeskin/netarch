#!/bin/bash
# ============================================================
# netarch-setup.sh
# VPS Dual Subnet Setup: NAT (10.0.1.0/24) + Isolated (10.0.2.0/24)
# Target: root@203.0.113.5
#
# Usage:
#   scp netarch-setup.sh root@203.0.113.5:/tmp/
#   ssh root@203.0.113.5 "bash /tmp/netarch-setup.sh"
#
# Risk Level: [NETWORK CHANGE] — modifies networking and iptables.
#             SSH access is preserved at every step.
#             Rollback: sudo iptables -F && sudo iptables -P INPUT ACCEPT
#                       && sudo iptables -P FORWARD ACCEPT
# ============================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[netarch]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================
# STEP 0 — Detect public interface
# ============================================================
log "Detecting public interface..."
PUBLIC_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)

if [[ -z "$PUBLIC_IFACE" ]]; then
    err "Could not auto-detect public interface. Falling back to eth0."
    PUBLIC_IFACE="eth0"
fi
log "Public interface: $PUBLIC_IFACE"

# ============================================================
# STEP 1 — Install prerequisites
# ============================================================
log "Installing bridge-utils and iptables-persistent..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    bridge-utils \
    iptables \
    netfilter-persistent \
    iptables-persistent

# ============================================================
# STEP 2 — Enable IP forwarding (required for NAT on vmbr1)
# ============================================================
log "Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Persist across reboots
if ! grep -q 'net.ipv4.ip_forward' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
else
    sed -i 's/^#*\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
fi
sysctl -p /etc/sysctl.conf > /dev/null
log "IP forwarding enabled and persisted."

# ============================================================
# STEP 3 — Create vmbr1 (NAT bridge) and vmbr2 (isolated bridge)
#           We append to /etc/network/interfaces
# ============================================================
log "Configuring /etc/network/interfaces..."

# Backup existing config
cp /etc/network/interfaces /etc/network/interfaces.netarch-backup-$(date +%Y%m%d%H%M%S)
log "Backed up /etc/network/interfaces"

# Check if vmbr1 already defined
if grep -q 'vmbr1' /etc/network/interfaces; then
    warn "vmbr1 already found in /etc/network/interfaces — skipping bridge config append."
    warn "Review /etc/network/interfaces manually if needed."
else
    cat >> /etc/network/interfaces << EOF

# --- netarch: NAT Bridge (internet access for 10.0.1.0/24) ---
auto vmbr1
iface vmbr1 inet static
    address 10.0.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '10.0.1.0/24' -o ${PUBLIC_IFACE} -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.0.1.0/24' -o ${PUBLIC_IFACE} -j MASQUERADE

# --- netarch: Isolated Bridge (no internet, no external access) ---
auto vmbr2
iface vmbr2 inet static
    address 10.0.2.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
    log "Bridge config written to /etc/network/interfaces"
fi

# ============================================================
# STEP 4 — Bring up bridges
# ============================================================
log "Bringing up vmbr1 (NAT bridge)..."
if ! ip link show vmbr1 &>/dev/null; then
    brctl addbr vmbr1
fi
ip addr flush dev vmbr1 2>/dev/null || true
ip addr add 10.0.1.1/24 dev vmbr1
ip link set vmbr1 up
log "vmbr1 is up at 10.0.1.1/24"

log "Bringing up vmbr2 (isolated bridge)..."
if ! ip link show vmbr2 &>/dev/null; then
    brctl addbr vmbr2
fi
ip addr flush dev vmbr2 2>/dev/null || true
ip addr add 10.0.2.1/24 dev vmbr2
ip link set vmbr2 up
log "vmbr2 is up at 10.0.2.1/24"

# ============================================================
# STEP 5 — iptables ruleset
#
# Safety order: ESTABLISHED/SSH ACCEPT first, DROP policy last.
# This ensures SSH on port 22 survives the transition.
# ============================================================
log "Applying iptables rules..."

# --- Flush existing rules (start clean) ---
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X 2>/dev/null || true

# --- INPUT chain ---
# Allow established/related connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
# Allow SSH — CRITICAL: must be before DROP policy
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# Allow ICMP (ping) for diagnostics
iptables -A INPUT -p icmp -j ACCEPT
# Set INPUT policy to DROP (host is protected)
iptables -P INPUT DROP

# --- FORWARD chain ---
# Allow existing connections through (stateful)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# NAT subnet (10.0.1.0/24): allow forwarding to internet
iptables -A FORWARD -s 10.0.1.0/24 -o "${PUBLIC_IFACE}" -j ACCEPT

# Isolated subnet (10.0.2.0/24): BLOCK all outbound forwarding
# This rule drops any attempt by 10.0.2.x to reach outside
iptables -A FORWARD -s 10.0.2.0/24 -j DROP

# Block inbound to isolated subnet from anywhere external
iptables -A FORWARD -d 10.0.2.0/24 -j DROP

# Block cross-subnet: NAT subnet cannot reach isolated subnet
iptables -A FORWARD -s 10.0.1.0/24 -d 10.0.2.0/24 -j DROP

# Default FORWARD policy: DROP everything not explicitly allowed
iptables -P FORWARD DROP

# OUTPUT stays ACCEPT (host outbound unrestricted)
iptables -P OUTPUT ACCEPT

# --- NAT table: masquerade for 10.0.1.0/24 ---
iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o "${PUBLIC_IFACE}" -j MASQUERADE

log "iptables rules applied."

# ============================================================
# STEP 6 — Persist iptables rules
# ============================================================
log "Persisting iptables rules..."
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
netfilter-persistent save
log "iptables rules saved to /etc/iptables/rules.v4"

# ============================================================
# STEP 7 — Verification
# ============================================================
log ""
log "======================================================="
log "VERIFICATION"
log "======================================================="

echo ""
echo "--- Bridges ---"
ip addr show vmbr1 | grep -E 'inet |state'
ip addr show vmbr2 | grep -E 'inet |state'

echo ""
echo "--- IP Forwarding ---"
FWD=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ "$FWD" == "1" ]]; then
    log "IP forwarding: ENABLED"
else
    err "IP forwarding: DISABLED (NAT will not work!)"
fi

echo ""
echo "--- iptables FORWARD chain ---"
iptables -L FORWARD -n -v --line-numbers

echo ""
echo "--- iptables NAT table ---"
iptables -t nat -L POSTROUTING -n -v

echo ""
echo "--- Routing table ---"
ip route show

log ""
log "======================================================="
log "SETUP COMPLETE"
log "======================================================="
log ""
log "Subnet summary:"
log "  10.0.1.0/24 (vmbr1) -> Internet: YES  | Isolated: NO"
log "  10.0.2.0/24 (vmbr2) -> Internet: NO   | Isolated: YES"
log ""
log "Next steps:"
log "  1. Assign VMs to vmbr1 (NAT) or vmbr2 (isolated)"
log "  2. Configure VM static IPs:"
log "     NAT VM:      10.0.1.x/24  gw 10.0.1.1  dns 1.1.1.1"
log "     Isolated VM: 10.0.2.x/24  gw 10.0.2.1  (no DNS needed)"
log "  3. Verify from inside a VM:"
log "     NAT VM:      ping 8.8.8.8  (should succeed)"
log "     Isolated VM: ping 8.8.8.8  (should fail/timeout)"
log ""
log "Rollback (if anything breaks):"
log "  sudo iptables -F"
log "  sudo iptables -t nat -F"
log "  sudo iptables -P INPUT ACCEPT"
log "  sudo iptables -P FORWARD ACCEPT"
