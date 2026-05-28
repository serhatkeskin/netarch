# VPS Dual Subnet Network Architecture

## Overview

This guide configures two separate subnets on your VPS (203.0.113.5):

- **10.0.1.0/24** — NAT subnet: VMs can reach the internet via NAT masquerade
- **10.0.2.0/24** — Isolated subnet: No inbound or outbound external access

The host VPS acts as a virtual router/firewall between these networks.

---

## Architecture Diagram

```
Internet
    |
[203.0.113.5] (VPS host)
    |           |
[virbr1]    [virbr2]
10.0.1.1    10.0.2.1
    |           |
10.0.1.0/24  10.0.2.0/24
(NAT, internet  (Isolated,
 access)         no external)
```

---

## Prerequisites

Log in to the VPS:
```bash
ssh root@203.0.113.5
```

Install required tools (if not already installed):
```bash
apt update && apt install -y bridge-utils iptables iproute2 dnsmasq
# On RHEL/CentOS:
# yum install -y bridge-utils iptables iproute2 dnsmasq
```

Enable IP forwarding (required for routing between interfaces):
```bash
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
```

---

## Step 1: Create Virtual Bridge Interfaces

Create two Linux bridges — one per subnet.

### Bridge for 10.0.1.0/24 (NAT / internet access)

```bash
# Create bridge
ip link add name virbr1 type bridge
ip link set virbr1 up
ip addr add 10.0.1.1/24 dev virbr1
```

### Bridge for 10.0.2.0/24 (Isolated)

```bash
# Create bridge
ip link add name virbr2 type bridge
ip link set virbr2 up
ip addr add 10.0.2.1/24 dev virbr2
```

Verify:
```bash
ip addr show virbr1
ip addr show virbr2
```

---

## Step 2: Make Bridge Configuration Persistent

### On Debian/Ubuntu — using /etc/network/interfaces

```bash
cat >> /etc/network/interfaces << 'EOF'

# NAT subnet bridge
auto virbr1
iface virbr1 inet static
    address 10.0.1.1
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0

# Isolated subnet bridge
auto virbr2
iface virbr2 inet static
    address 10.0.2.1
    netmask 255.255.255.0
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF
```

### On RHEL/CentOS — using NetworkManager

```bash
# NAT bridge
nmcli connection add type bridge ifname virbr1 con-name virbr1
nmcli connection modify virbr1 ipv4.method manual ipv4.addresses 10.0.1.1/24
nmcli connection modify virbr1 bridge.stp no
nmcli connection up virbr1

# Isolated bridge
nmcli connection add type bridge ifname virbr2 con-name virbr2
nmcli connection modify virbr2 ipv4.method manual ipv4.addresses 10.0.2.1/24
nmcli connection modify virbr2 bridge.stp no
nmcli connection up virbr2
```

---

## Step 3: Configure iptables Firewall Rules

### Determine the public-facing interface name

```bash
ip route get 8.8.8.8 | awk '{print $5; exit}'
# Typically: eth0 or ens3 or similar
```

In the commands below, replace `eth0` with your actual public interface name.

### Flush existing rules (optional — skip if you have existing rules to preserve)

```bash
iptables -F
iptables -t nat -F
iptables -X
```

### Set default policies

```bash
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
```

### Allow established/related connections

```bash
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### Allow SSH to the host

```bash
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
```

### Allow loopback

```bash
iptables -A INPUT -i lo -j ACCEPT
```

### NAT subnet (10.0.1.0/24) — Allow internet access via masquerade

```bash
# Allow forwarding from virbr1 to the internet (eth0)
iptables -A FORWARD -i virbr1 -o eth0 -j ACCEPT

# Allow return traffic
iptables -A FORWARD -i eth0 -o virbr1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Masquerade (SNAT) outbound traffic from 10.0.1.0/24
iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o eth0 -j MASQUERADE
```

### Isolated subnet (10.0.2.0/24) — Block all external access

```bash
# Block forwarding from virbr2 to internet
iptables -A FORWARD -i virbr2 -o eth0 -j DROP

# Block forwarding from internet to virbr2
iptables -A FORWARD -i eth0 -o virbr2 -j DROP

# Allow intra-subnet communication (virbr2 to virbr2)
iptables -A FORWARD -i virbr2 -o virbr2 -j ACCEPT

# Block forwarding between subnets (virbr1 <-> virbr2)
iptables -A FORWARD -i virbr1 -o virbr2 -j DROP
iptables -A FORWARD -i virbr2 -o virbr1 -j DROP

# Allow host-to-virbr2 communication (host can still manage isolated VMs)
iptables -A INPUT -i virbr2 -j ACCEPT
```

### Save iptables rules persistently

```bash
# On Debian/Ubuntu:
apt install -y iptables-persistent
netfilter-persistent save

# On RHEL/CentOS:
service iptables save
# or:
iptables-save > /etc/sysconfig/iptables
```

---

## Step 4: Configure DHCP (Optional but Recommended)

Using dnsmasq to provide DHCP on both bridges.

### /etc/dnsmasq.d/virbr1.conf (NAT subnet)

```bash
cat > /etc/dnsmasq.d/virbr1.conf << 'EOF'
interface=virbr1
bind-interfaces
dhcp-range=10.0.1.100,10.0.1.200,255.255.255.0,12h
dhcp-option=3,10.0.1.1       # Default gateway = host
dhcp-option=6,8.8.8.8,8.8.4.4  # DNS servers
EOF
```

### /etc/dnsmasq.d/virbr2.conf (Isolated subnet)

```bash
cat > /etc/dnsmasq.d/virbr2.conf << 'EOF'
interface=virbr2
bind-interfaces
dhcp-range=10.0.2.100,10.0.2.200,255.255.255.0,12h
# No gateway or external DNS — keeps subnet isolated
EOF
```

Restart dnsmasq:
```bash
systemctl restart dnsmasq
systemctl enable dnsmasq
```

---

## Step 5: Attach VMs to the Bridges

When creating or configuring VMs (KVM/QEMU example):

### VM on NAT subnet (can reach internet)

```bash
virt-install \
  --name vm-nat-1 \
  --ram 1024 \
  --vcpus 1 \
  --disk path=/var/lib/libvirt/images/vm-nat-1.qcow2,size=10 \
  --network bridge=virbr1,model=virtio \
  --os-type linux \
  --os-variant ubuntu20.04 \
  --graphics none \
  --import
```

### VM on Isolated subnet (no internet)

```bash
virt-install \
  --name vm-iso-1 \
  --ram 1024 \
  --vcpus 1 \
  --disk path=/var/lib/libvirt/images/vm-iso-1.qcow2,size=10 \
  --network bridge=virbr2,model=virtio \
  --os-type linux \
  --os-variant ubuntu20.04 \
  --graphics none \
  --import
```

---

## Step 6: Verify Configuration

### Check bridges are up

```bash
ip addr show virbr1
ip addr show virbr2
brctl show
```

### Check iptables rules

```bash
iptables -L -v -n
iptables -t nat -L -v -n
```

### Test NAT subnet (from a VM on 10.0.1.0/24)

```bash
# Should succeed:
ping -c 3 8.8.8.8
curl -s https://ifconfig.me   # Should show VPS public IP
```

### Test Isolated subnet (from a VM on 10.0.2.0/24)

```bash
# Should FAIL (no route to external):
ping -c 3 8.8.8.8
curl -s https://ifconfig.me

# Should SUCCEED (intra-subnet):
ping -c 3 10.0.2.1    # Host gateway
ping -c 3 10.0.2.101  # Another VM on same subnet
```

### Test inter-subnet isolation

```bash
# From a VM on 10.0.1.0/24, should FAIL:
ping -c 3 10.0.2.101

# From a VM on 10.0.2.0/24, should FAIL:
ping -c 3 10.0.1.101
```

---

## Complete iptables Rule Summary

```bash
# View all active rules at once:
iptables -L -v -n --line-numbers
iptables -t nat -L -v -n --line-numbers
```

Expected rule structure:

| Chain | Rule | Purpose |
|-------|------|---------|
| INPUT | ACCEPT established,related | Return traffic |
| INPUT | ACCEPT tcp dpt:22 | SSH to host |
| INPUT | ACCEPT lo | Loopback |
| INPUT | ACCEPT virbr2 | Host manages isolated VMs |
| INPUT | DROP (default) | Block everything else |
| FORWARD | ACCEPT established,related | Return forwarding |
| FORWARD | ACCEPT virbr1 -> eth0 | NAT subnet outbound |
| FORWARD | ACCEPT eth0 -> virbr1 established | NAT return traffic |
| FORWARD | ACCEPT virbr2 -> virbr2 | Intra-isolated traffic |
| FORWARD | DROP virbr2 -> eth0 | Block isolated outbound |
| FORWARD | DROP eth0 -> virbr2 | Block external to isolated |
| FORWARD | DROP virbr1 <-> virbr2 | Block cross-subnet |
| FORWARD | DROP (default) | Block everything else |
| POSTROUTING (nat) | MASQUERADE 10.0.1.0/24 -> eth0 | NAT for internet |

---

## Security Notes

1. The isolated subnet (10.0.2.0/24) has zero external reachability — inbound and outbound to/from the internet are both blocked.
2. Cross-subnet traffic between 10.0.1.0/24 and 10.0.2.0/24 is explicitly dropped.
3. The VPS host itself can still SSH into VMs on virbr2 for management purposes via 10.0.2.x addresses.
4. If you do NOT want the host to reach the isolated subnet either, remove the `iptables -A INPUT -i virbr2 -j ACCEPT` rule and add a drop rule instead.
5. Always verify `net.ipv4.ip_forward = 1` is set, or NAT will silently fail.
