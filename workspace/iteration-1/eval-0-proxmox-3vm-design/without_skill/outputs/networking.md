# Proxmox 3-VM Network Mimarisi

## Hedef Topoloji

```
Internet
    |
    | (WAN)
[Proxmox Host / Router]
    |
    +--- vmbr0 (WAN bridge) --- Web VM (192.168.1.10)
    |
    +--- vmbr1 (LAN bridge, izole)
              |
              +--- App VM  (10.0.1.10)
              +--- DB VM   (10.0.1.20)
```

Daha doğru bir diyagram:

```
Internet
    |
[Proxmox vmbr0 - WAN: 203.0.113.1]
    |
[Web VM] ----vmbr0 (public) + vmbr1 (private: 10.0.1.10)
                                      |
                               [App VM: 10.0.1.20]
                                      |
                               [DB VM:  10.0.1.30]
```

### Erişim Kuralları
| Kaynak      | Hedef      | Port        | Durum   |
|-------------|------------|-------------|---------|
| Internet    | Web VM     | 80, 443     | ACIK    |
| Internet    | App VM     | *           | KAPALI  |
| Internet    | DB VM      | *           | KAPALI  |
| Web VM      | App VM     | 8080 (ornek)| ACIK    |
| App VM      | DB VM      | 5432 (PG)   | ACIK    |
| DB VM       | App VM     | *           | KAPALI  |
| Web VM      | Internet   | *           | ACIK    |
| App VM      | Internet   | *           | ACIK    |
| DB VM       | Internet   | KAPALI (opsiyonel) | -  |

---

## Adim 1: Proxmox'ta Bridge'leri Olusturun

Proxmox host'unuzda `/etc/network/interfaces` dosyasini duzenleyin:

```bash
# /etc/network/interfaces

auto lo
iface lo inet loopback

# WAN arayuzu (fiziksel)
auto eno1
iface eno1 inet manual

# vmbr0 - WAN Bridge (internete baglidir)
auto vmbr0
iface vmbr0 inet static
    address 203.0.113.1/24      # ISP'nizden gelen public IP
    gateway 203.0.113.254
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0

# vmbr1 - Private LAN Bridge (izole, sadece VM'ler arasi)
auto vmbr1
iface vmbr1 inet static
    address 10.0.1.1/24         # Proxmox host'un LAN IP'si (gateway gorevi)
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

Degisiklikleri uygulayın:
```bash
systemctl restart networking
# veya
ifreload -a
```

---

## Adim 2: VM'lerin Network Karti Yapilandirmasi

### Web VM
- **NIC 1**: vmbr0 (WAN - public IP alir)
- **NIC 2**: vmbr1 (LAN - 10.0.1.10)

Proxmox GUI'den: Web VM -> Hardware -> Add -> Network Device
- Net0: Bridge=vmbr0, Model=VirtIO
- Net1: Bridge=vmbr1, Model=VirtIO

### App VM
- **NIC 1**: vmbr1 (LAN - 10.0.1.20) SADECE
- Internet erisimi icin NAT (asagida ayarlanacak)

### DB VM
- **NIC 1**: vmbr1 (LAN - 10.0.1.30) SADECE
- Internet erisimi KAPALI (veya NAT ile kisitli)

---

## Adim 3: VM Icindeki IP Yapilandirmasi

### Web VM (Ubuntu/Debian ornegi)

```bash
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    ens18:    # vmbr0 -> public NIC
      dhcp4: false
      addresses:
        - 203.0.113.10/24
      routes:
        - to: default
          via: 203.0.113.254
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
    ens19:    # vmbr1 -> private NIC
      dhcp4: false
      addresses:
        - 10.0.1.10/24
```

```bash
netplan apply
```

### App VM

```bash
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    ens18:    # vmbr1 -> private NIC
      dhcp4: false
      addresses:
        - 10.0.1.20/24
      routes:
        - to: default
          via: 10.0.1.1    # Proxmox host LAN IP'si (NAT gateway)
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

### DB VM

```bash
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    ens18:    # vmbr1 -> private NIC
      dhcp4: false
      addresses:
        - 10.0.1.30/24
      # DB'nin internete cikmasi gerekmiyorsa route ekleme
      # Gerekirse: via: 10.0.1.1
      nameservers:
        addresses: [10.0.1.1]  # Sadece yerel cozum
```

---

## Adim 4: Proxmox Host'ta NAT ve IP Forwarding

App VM (ve opsiyonel olarak Web VM'in LAN arayuzu) internete cikabilmesi icin Proxmox host'ta NAT ayarlayın.

### IP Forwarding'i Etkinlestirin

```bash
# Gecici:
echo 1 > /proc/sys/net/ipv4/ip_forward

# Kalici (/etc/sysctl.conf):
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
```

### iptables Kurallari

```bash
# Mevcut kurallari goster
iptables -L -n -v
iptables -t nat -L -n -v

# LAN'dan WAN'a NAT (masquerade)
# App VM ve DB VM internete ciksin
iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o vmbr0 -j MASQUERADE

# LAN'dan gelen paketlerin forward edilmesine izin ver
iptables -A FORWARD -i vmbr1 -o vmbr0 -j ACCEPT

# Established/related baglantilara izin ver (donus trafikl)
iptables -A FORWARD -i vmbr0 -o vmbr1 -m state --state ESTABLISHED,RELATED -j ACCEPT

# Disaridan LAN'a yeni baglanti girmesin (guvenlik)
iptables -A FORWARD -i vmbr0 -o vmbr1 -m state --state NEW -j DROP
```

### Kurallari Kalici Hale Getirin

```bash
apt install iptables-persistent -y
netfilter-persistent save
```

---

## Adim 5: Guvenlik Duvari (VM Bazli)

### Web VM - UFW

```bash
ufw default deny incoming
ufw default allow outgoing

# SSH erisimi (yonetim icin)
ufw allow 22/tcp

# Web trafiklerine izin ver
ufw allow 80/tcp
ufw allow 443/tcp

# App VM'e istek gonderebilsin (cikis zaten acik)
# App VM'den geri donus otomatik kabul edilir

ufw enable
ufw status verbose
```

### App VM - UFW

```bash
ufw default deny incoming
ufw default allow outgoing

# SSH sadece Web VM veya yonetim agından
ufw allow from 10.0.1.10 to any port 22

# Web VM'den gelen istekleri kabul et (ornegin port 8080)
ufw allow from 10.0.1.10 to any port 8080

# Herhangi bir disaridan giris kapatili (NAT arkasinda zaten)

ufw enable
```

### DB VM - UFW

```bash
ufw default deny incoming
ufw default allow outgoing

# SSH sadece App VM'den
ufw allow from 10.0.1.20 to any port 22

# PostgreSQL sadece App VM'den
ufw allow from 10.0.1.20 to any port 5432

# MySQL kullaniyorsaniz
# ufw allow from 10.0.1.20 to any port 3306

# Baska hicbir giris kabul edilmez

ufw enable
ufw status verbose
```

---

## Adim 6: Proxmox Firewall (Opsiyonel - Ekstra Guvenlik)

Proxmox'un kendi firewall'unu da kullanabilirsiniz. Datacenter -> Firewall -> Options -> Enable: Yes

### Datacenter Firewall Kuralı (GUI veya CLI)

```
# /etc/pve/firewall/cluster.fw

[OPTIONS]
enable: 1

[RULES]
# Web VM'e HTTP/HTTPS izin ver (VMID ornegi: 101)
IN ACCEPT -dest 203.0.113.10 -dport 80 -p tcp
IN ACCEPT -dest 203.0.113.10 -dport 443 -p tcp

# DB VM'e sadece App VM'den erisim (VMID: 103)
IN ACCEPT -source 10.0.1.20 -dest 10.0.1.30 -dport 5432 -p tcp

# Diger her sey engelle
IN DROP
```

---

## Adim 7: Veritabani Baglantisini Test Edin

```bash
# App VM'den DB'ye baglanti testi
# App VM uzerinde:
nc -zv 10.0.1.30 5432
telnet 10.0.1.30 5432

# PostgreSQL ise:
psql -h 10.0.1.30 -U appuser -d mydb

# MySQL/MariaDB ise:
mysql -h 10.0.1.30 -u appuser -p

# Web VM'den DB'ye erisim OLMAMALI:
nc -zv 10.0.1.30 5432   # Bu BASARISIZ olmali
```

---

## Adim 8: Internet Erisimini Test Edin

```bash
# App VM'den internet testi:
ping 8.8.8.8
curl -I https://google.com

# DB VM'den internet testi (kapatildiysa basarisiz olmali):
ping 8.8.8.8   # Timeout olmali

# Web VM'den internet testi:
curl -I https://google.com   # Basarili olmali
```

---

## Ozet Mimari

```
                    INTERNET
                       |
              [203.0.113.254 - ISP Gateway]
                       |
              [203.0.113.1 - vmbr0 (WAN)]
                       |
              [PROXMOX HOST - NAT/Firewall]
              [10.0.1.1 - vmbr1 (LAN)]
                       |
          +------------+------------+
          |                         |
   [Web VM]                  [App VM]----[DB VM]
   vmbr0: 203.0.113.10       10.0.1.20   10.0.1.30
   vmbr1: 10.0.1.10
   Acik: 80, 443             Acik: 8080  Acik: 5432
   Internet: EVET            (sadece     (sadece
                             Web VM'den) App VM'den)
                             Internet: EVET
                                         Internet: HAYIR
```

---

## Sorun Giderme

```bash
# Proxmox host'ta routing tablosunu kontrol et
ip route show

# iptables kurallarini listele
iptables -L -n -v --line-numbers
iptables -t nat -L -n -v

# VM'ler arasi ping testi
# Web VM'den App VM'e:
ping 10.0.1.20

# Paket izleme (troubleshooting)
tcpdump -i vmbr1 -n port 5432

# UFW log'larini incele
grep UFW /var/log/kern.log | tail -20
```

---

## Guvenlik Onerileri

1. **SSH Key Authentication**: Sifre yerine SSH key kullanin
2. **Fail2Ban**: Brute force saldirilarindan korunmak icin Web VM'e kurun
3. **DB Sifresi**: Guclu ve uniq sifre kullanin; remote root girisi kapatın
4. **SSL/TLS**: Web VM'de Let's Encrypt ile HTTPS zorunlu hale getirin
5. **Backup**: Proxmox'un snapshot ozelligini duzenli kullannın
6. **Log Monitoring**: App ve DB VM'lerde `journalctl` ile log takibi yapın
7. **Updates**: Tum VM'leri duzenli guncelleyin (`apt update && apt upgrade`)
