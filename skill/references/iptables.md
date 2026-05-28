# iptables Patterns for Network Segmentation

## Rule Order Matters

iptables evaluates rules top-to-bottom, stops at first match. Put:
1. ESTABLISHED/RELATED first (fast path for existing connections)
2. Specific ACCEPT rules before broad DROP rules
3. Default DROP policy last (or use `-P DROP`)

## Essential Baseline Ruleset

```bash
#!/bin/bash
# Apply in this order to avoid locking yourself out

# 1. Allow established connections first (most important)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# 2. Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# 3. Allow SSH (BEFORE setting INPUT DROP policy)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 4. Allow ICMP (ping) — useful for troubleshooting
iptables -A INPUT -p icmp -j ACCEPT

# 5. Now set restrictive policy (safe because SSH is already allowed)
iptables -P INPUT DROP
iptables -P FORWARD DROP
# OUTPUT stays ACCEPT (outbound usually unrestricted)
```

## NAT / Masquerade

```bash
# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
# Persist:
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf

# Masquerade internal subnet through public interface
iptables -t nat -A POSTROUTING -s 10.10.1.0/24 -o vmbr0 -j MASQUERADE

# Specific source NAT (fixed outbound IP instead of dynamic)
iptables -t nat -A POSTROUTING -s 10.10.1.0/24 -o eth0 -j SNAT --to-source 203.0.113.5
```

## Port Forwarding (DNAT)

```bash
# Forward public port 80 to internal VM
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 80 -j DNAT --to-destination 10.10.1.10:80

# Forward non-standard port to internal SSH
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 2222 -j DNAT --to-destination 10.10.2.10:22

# Allow the forwarded traffic through FORWARD chain
iptables -A FORWARD -p tcp -d 10.10.1.10 --dport 80 -j ACCEPT
```

## Subnet Isolation Patterns

```bash
# Allow internal subnet to reach internet
iptables -A FORWARD -s 10.10.2.0/24 -o vmbr0 -j ACCEPT

# Block DMZ from reaching internal subnet (security boundary)
iptables -A FORWARD -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP

# Allow specific DMZ host to reach one internal port only
iptables -A FORWARD -s 10.10.1.10 -d 10.10.2.10 -p tcp --dport 5432 -j ACCEPT

# Allow internal to reach DMZ (but not vice versa)
iptables -A FORWARD -s 10.10.2.0/24 -d 10.10.1.0/24 -j ACCEPT
iptables -A FORWARD -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP
```

## Rate Limiting

```bash
# Limit new SSH connections (brute force protection)
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Limit ICMP (ping flood protection)
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
```

## Logging

```bash
# Log dropped packets (before DROP rule)
iptables -A FORWARD -s 10.10.1.0/24 -d 10.10.2.0/24 -j LOG --log-prefix "NETARCH DROP: " --log-level 4
iptables -A FORWARD -s 10.10.1.0/24 -d 10.10.2.0/24 -j DROP

# View logs
journalctl -k | grep "NETARCH DROP"
# or
dmesg | grep "NETARCH DROP"
```

## Persistence

```bash
# Save current rules
sudo iptables-save > /etc/iptables/rules.v4

# Restore on boot (Debian/Ubuntu)
sudo apt install iptables-persistent
sudo netfilter-persistent save

# Manual restore
sudo iptables-restore < /etc/iptables/rules.v4
```

On Proxmox, prefer `/etc/network/interfaces` post-up hooks for bridge-specific rules — they're applied automatically when the interface comes up.

## Rollback (Full Reset)

```bash
# Emergency: remove all rules, allow everything
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
```

**Always have this ready before applying restrictive rules over SSH.**

## Diagnostic Commands

```bash
# Show filter table with packet counts
sudo iptables -L -n -v --line-numbers

# Show nat table
sudo iptables -t nat -L -n -v

# Show mangle table
sudo iptables -t mangle -L -n -v

# Trace a specific packet (requires iptables-extensions)
sudo iptables -t raw -A PREROUTING -s 10.10.1.10 -j TRACE
sudo iptables -t raw -A OUTPUT -d 10.10.1.10 -j TRACE
# Read trace
sudo modprobe nf_log_ipv4
sudo sysctl net.netfilter.nf_log.2=nf_log_ipv4
dmesg | grep TRACE

# Check if connection tracking is working
sudo conntrack -L | head -20
```
