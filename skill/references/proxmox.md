# Proxmox Networking Reference

## Bridge Types

| Type | Use Case | Config |
|------|----------|--------|
| `vmbr0` | Public-facing, upstream WAN | Usually bound to physical NIC |
| `vmbr1+` | Internal isolated networks | `bridge-ports none` (NAT bridge) |

## /etc/network/interfaces Patterns

### NAT Bridge (internal VMs get internet via host NAT)
```
auto vmbr1
iface vmbr1 inet static
    address 10.10.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '10.10.1.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.1.0/24' -o vmbr0 -j MASQUERADE
```

### Routed Bridge (no NAT, public IPs on VMs)
```
auto vmbr1
iface vmbr1 inet static
    address 203.0.113.1/29
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   ip route add 203.0.113.0/29 dev vmbr1
```

### VLAN-aware Bridge
```
auto vmbr0
iface vmbr0 inet static
    address 192.168.1.100/24
    gateway 192.168.1.1
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

## Applying Bridge Changes

```bash
# Apply without full reboot (Proxmox)
sudo ifreload -a

# Or restart networking (causes brief downtime)
sudo systemctl restart networking
```

**Warning:** Applying bridge changes via SSH may drop your connection if vmbr0 is affected. Consider console access.

## VM Network Config (inside VM)

### Static IP (Debian/Ubuntu)
```
# /etc/network/interfaces
auto eth0
iface eth0 inet static
    address 10.10.1.10/24
    gateway 10.10.1.1
    dns-nameservers 1.1.1.1 8.8.8.8
```

### Netplan (Ubuntu 20.04+)
```yaml
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.10.1.10/24]
      routes:
        - to: default
          via: 10.10.1.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

## Multi-Subnet Isolation Topology

```
Proxmox Host
├── vmbr0 ── Physical NIC ── Internet
│     └── Router/Firewall VM (eth0=vmbr0, eth1=vmbr1, eth2=vmbr2)
├── vmbr1 (10.10.1.0/24) ── DMZ
│     ├── Web VM (10.10.1.10)
│     └── Reverse Proxy VM (10.10.1.11)
└── vmbr2 (10.10.2.0/24) ── Internal
      ├── DB VM (10.10.2.10)
      └── App VM (10.10.2.11)
```

Traffic control lives in the Router/Firewall VM, not the host.
Host-level iptables FORWARD policy should be ACCEPT (or carefully tuned) to let the firewall VM handle policy.

## Proxmox Firewall vs Host iptables

| Layer | Where | Best for |
|-------|-------|----------|
| Proxmox Datacenter Firewall | Web UI → Datacenter → Firewall | Management network protection |
| Proxmox VM Firewall | Web UI → VM → Firewall | Per-VM rules |
| Host iptables | SSH to node, `/etc/network/interfaces` post-up | NAT, routing between bridges |
| Firewall VM (pfSense/OPNsense) | Inside a VM | Full stateful firewall, IDS, VPN |

Recommendation: Use Proxmox VM Firewall for basic per-VM protection. Use a dedicated Firewall VM for complex policies.

## Useful Proxmox Diagnostics

```bash
# Show all bridges and connected VMs
brctl show

# Show bridge VLAN info
bridge vlan show

# Check if a VM NIC is on a bridge
ip link show master vmbr1

# OVS bridges (if using Open vSwitch)
ovs-vsctl show

# Network config in Proxmox DB
cat /etc/pve/nodes/$(hostname)/config
```
