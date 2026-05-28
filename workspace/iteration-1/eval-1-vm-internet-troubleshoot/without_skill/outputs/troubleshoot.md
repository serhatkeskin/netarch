# Proxmox vmbr1 - VM Internet Erişim Sorunu Giderme Kılavuzu

## Sorun Tanımı

VM'ler vmbr1 bridge'e bağlı ve 10.10.1.10/24 IP adresine sahip, ancak internete (dışarıya) ping atamıyorlar.

---

## Olası Nedenler ve Kontrol Adımları

### 1. Default Gateway Kontrolü (VM İçinde)

VM'de çalıştırılacak komutlar:

```bash
# Routing tablosunu kontrol et
ip route show

# Default gateway var mı?
ip route show default
```

**Beklenen çıktı:**
```
default via 10.10.1.1 dev eth0
10.10.1.0/24 dev eth0 proto kernel scope link src 10.10.1.10
```

**Sorun:** Eğer `default via ...` satırı yoksa, default gateway tanımlı değildir.

**Düzeltme:**
```bash
# Geçici olarak ekle
ip route add default via 10.10.1.1

# Kalıcı yapmak için (Debian/Ubuntu):
# /etc/network/interfaces dosyasına ekle:
# gateway 10.10.1.1
```

---

### 2. Proxmox Host - IP Forwarding Kontrolü

Proxmox ana makinede (host) çalıştırılacak komutlar:

```bash
# IP forwarding aktif mi?
cat /proc/sys/net/ipv4/ip_forward

# 1 ise aktif, 0 ise kapalı
```

**Düzeltme - IP Forwarding'i Etkinleştir:**
```bash
# Geçici (reboot sonrası sıfırlanır)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Kalıcı
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
```

---

### 3. NAT / Masquerade Kuralı Kontrolü (Proxmox Host)

vmbr1 büyük ihtimalle private/internal bir bridge'dir ve internete çıkabilmek için NAT gerekir.

```bash
# Mevcut iptables NAT kurallarını kontrol et
iptables -t nat -L POSTROUTING -n -v

# ya da nftables kullanılıyorsa
nft list ruleset | grep masquerade
```

**Eğer NAT kuralı yoksa:**

```bash
# vmbr0 = WAN/internet'e bağlı interface (Proxmox host'un dış interface'i)
# vmbr1 = VM'lerin bağlı olduğu internal bridge

# NAT (masquerade) kuralı ekle
iptables -t nat -A POSTROUTING -s 10.10.1.0/24 -o vmbr0 -j MASQUERADE

# Kalıcı hale getirmek için
apt install iptables-persistent -y
netfilter-persistent save
```

**Alternatif - /etc/network/interfaces üzerinden kalıcı NAT:**

Proxmox host'ta `/etc/network/interfaces` dosyasını düzenle:

```
auto vmbr1
iface vmbr1 inet static
    address 10.10.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '10.10.1.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.1.0/24' -o vmbr0 -j MASQUERADE
```

---

### 4. vmbr1 Gateway IP Kontrolü (Proxmox Host)

```bash
# vmbr1 interface'inin IP adresi var mı? (Bu VM'lerin gateway'i olmalı)
ip addr show vmbr1

# vmbr1 up mu?
ip link show vmbr1
```

**Beklenen:** vmbr1'in 10.10.1.1/24 gibi bir IP'si olmalı ve VM'ler bu IP'yi gateway olarak kullanmalı.

---

### 5. DNS Çözümleme Kontrolü (VM İçinde)

IP ile ping atılabiliyorsa ama domain ile atılamıyorsa sorun DNS'tedir:

```bash
# IP ile test
ping 8.8.8.8

# Domain ile test
ping google.com

# DNS sunucusu kontrol
cat /etc/resolv.conf
```

**Düzeltme:**
```bash
# /etc/resolv.conf'a DNS ekle
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

---

### 6. Proxmox Firewall Kontrolü

Proxmox GUI veya CLI üzerinden:

```bash
# Proxmox firewall aktif mi?
pvesh get /cluster/firewall/options

# VM'nin firewall kuralları
cat /etc/pve/firewall/<VMID>.fw
```

Proxmox GUI'de: Datacenter > Firewall veya VM > Firewall sekmelerini kontrol et. Eggress trafiğini engelleyen bir kural olabilir.

---

### 7. VM'den Adım Adım Ping Testi

```bash
# 1. Gateway'e ping (vmbr1 IP'si - 10.10.1.1)
ping 10.10.1.1

# 2. Dış bir IP'ye ping (Google DNS)
ping 8.8.8.8

# 3. Domain'e ping
ping google.com
```

| Test | Sonuç | Anlam |
|------|-------|-------|
| 10.10.1.1 ping FAIL | Gateway erişilemiyor | vmbr1 IP yok veya VM'de yanlış gateway |
| 10.10.1.1 ping OK, 8.8.8.8 FAIL | NAT/forwarding sorunu | IP forward kapalı veya NAT kuralı yok |
| 8.8.8.8 ping OK, google.com FAIL | DNS sorunu | /etc/resolv.conf düzelt |

---

## Hızlı Çözüm Özeti

Proxmox host'ta bu komutları sırayla çalıştır:

```bash
# 1. IP forwarding aç
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 2. vmbr1'e IP ata (eğer yoksa)
ip addr add 10.10.1.1/24 dev vmbr1

# 3. NAT kuralı ekle (vmbr0'ı kendi WAN interface'inle değiştir)
iptables -t nat -A POSTROUTING -s 10.10.1.0/24 -o vmbr0 -j MASQUERADE

# 4. Kalıcı yap
netfilter-persistent save
```

VM içinde:
```bash
# Default gateway ayarla
ip route add default via 10.10.1.1

# DNS ayarla
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

# Test et
ping 8.8.8.8
```

---

## En Sık Karşılaşılan Senaryo

vmbr1 çoğunlukla "isolated" (izole) bir internal bridge olarak kurulur ve fiziksel bir ağ portuna bağlı değildir. Bu durumda:

- vmbr1'in kendisinin bir IP'si (10.10.1.1) olmalı — bu VM'lerin gateway'i
- Proxmox host'ta IP forwarding açık olmalı
- POSTROUTING masquerade kuralı ile VM trafiği dış interface (vmbr0) üzerinden NAT edilmeli

Bu üç şart sağlandığında VM'ler internete çıkabilir.
