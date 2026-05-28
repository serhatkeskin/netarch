# NetArch Troubleshoot — vmbr1 VM Internet Sorunu

**Sorun:** vmbr1 bridge'ine bağlı VM'ler (IP: 10.10.1.10/24) internet erişimi sağlayamıyor.  
**Mod:** Troubleshoot (Simülasyon — komutlar uygulanmaz, çalıştırılması gereken komutlar listelenir)

---

## Topoloji (Tahmin Edilen)

```
┌──────────────────────────────────────────────────┐
│                  INTERNET / WAN                  │
└─────────────────────┬────────────────────────────┘
                      │ vmbr0 (public IP / upstream)
            ┌─────────▼──────────┐
            │   Proxmox Host     │
            │  (NAT + routing)   │
            └──────────┬─────────┘
                       │
              ┌────────▼────────┐
              │  vmbr1 Bridge   │
              │  10.10.1.1/24   │
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │  VM: 10.10.1.10 │  <-- internete çıkamıyor
              └─────────────────┘
```

**En olası 3 neden:**
1. IP forwarding host'ta kapalı (`/proc/sys/net/ipv4/ip_forward = 0`)
2. MASQUERADE NAT kuralı eksik (vmbr1 trafiği vmbr0 üzerinden dışarıya çıkamıyor)
3. iptables FORWARD zinciri DROP politikasıyla engelliyor

---

## Phase 1 — Diagnostik Komutlar (READ-ONLY)

Aşağıdaki komutları Proxmox HOST üzerinde çalıştırın:

```bash
# 1. IP forwarding durumu (kritik — 0 ise NAT çalışmaz)
cat /proc/sys/net/ipv4/ip_forward

# 2. Tüm bridge ve arayüz durumları
ip addr show

# 3. Routing tablosu (default route var mı?)
ip route show

# 4. Bridge bağlantıları (VM NIC'leri vmbr1'de mi?)
brctl show
# veya
bridge link show

# 5. vmbr1'e bağlı interface'ler
ip link show master vmbr1

# 6. iptables filter tablosu (FORWARD zinciri kritik)
sudo iptables -L -n -v --line-numbers

# 7. iptables NAT tablosu (MASQUERADE kuralı var mı?)
sudo iptables -t nat -L -n -v

# 8. /etc/network/interfaces içeriği (post-up kuralları var mı?)
cat /etc/network/interfaces

# 9. VM içinden gateway'e ping (host'a ulaşabiliyor mu?)
# Bu komutu VM içinde çalıştırın:
ping -c 3 10.10.1.1

# 10. VM içinden dış IP'ye ping
# Bu komutu VM içinde çalıştırın:
ping -c 3 8.8.8.8

# 11. VM içinde routing tablosu ve gateway
# Bu komutu VM içinde çalıştırın:
ip route show
```

---

## Phase 2 — Tanı Tablosu (Simüle Edilmiş Bulgular)

Bu senaryo için en olası bulgular:

| # | Kontrol | Beklenen Durum | Simüle Edilen Bulgu | Sonuç |
|---|---------|----------------|---------------------|-------|
| 1 | IP Forwarding (`ip_forward`) | `1` | `0` | KRITIK — NAT/routing tamamen devre dışı |
| 2 | MASQUERADE NAT kuralı | Mevcut olmalı | Yok | NAT yapılamıyor, paketler dışarıya çıkamıyor |
| 3 | FORWARD zinciri politikası | ACCEPT veya ACCEPT kuralı | `FORWARD DROP` | vmbr1 → vmbr0 trafiği engelleniyor |
| 4 | vmbr1 bridge durumu | UP, 10.10.1.1/24 | UP — IP mevcut | Tamam |
| 5 | VM'nin gateway'i | 10.10.1.1 | 10.10.1.1 (veya eksik) | Doğrulama gerekiyor |
| 6 | VM → gateway ping | Başarılı | Başarılı | Bridge katmanı çalışıyor |
| 7 | VM → 8.8.8.8 ping | Başarılı | Başarısız | Host'ta yönlendirme yok |
| 8 | DNS çözümlemesi | Çalışıyor | Çalışmıyor | IP forwarding yoksa DNS de başarısız |

**Kök Neden:** IP forwarding kapalı + MASQUERADE kuralı eksik. Bu ikisi birlikte en yaygın "IP var ama internet yok" senaryosunu oluşturur.

---

## Phase 3 — Önerilen Düzeltme

### Onay Gerekiyor — Aşağıdaki script'i uygulamadan önce onaylayın.

**Genel Strateji:**
1. IP forwarding'i etkinleştir (kalıcı)
2. MASQUERADE NAT kuralı ekle (10.10.1.0/24 → vmbr0)
3. FORWARD zincirinde vmbr1 → vmbr0 trafiğine izin ver
4. Kuralları kalıcı hale getir (`/etc/network/interfaces` post-up hooks)

---

### Adım 1 — Hızlı Test (Geçici, reboot'ta kaybolur)

```bash
# [NETWORK CHANGE] IP forwarding'i hemen etkinleştir
echo 1 > /proc/sys/net/ipv4/ip_forward
# Neden: Bu olmadan host hiçbir paketi yönlendirmez.
# Risk: Düşük — sadece mevcut trafiğe izin verir, yeni bir kural eklemez.

# [NETWORK CHANGE] MASQUERADE kuralı ekle
# Dikkat: vmbr0 yerine kullandığınız public interface adını yazın (eth0 de olabilir)
iptables -t nat -A POSTROUTING -s '10.10.1.0/24' -o vmbr0 -j MASQUERADE
# Neden: VM'lerden gelen 10.10.1.x paketleri host'un public IP'si üzerinden dışarıya çıkar.
# Risk: Orta — NAT ekler, SSH bağlantısını etkilemez.

# [NETWORK CHANGE] FORWARD zincirinde geçişe izin ver
iptables -A FORWARD -s '10.10.1.0/24' -o vmbr0 -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
# Neden: FORWARD DROP politikası varsa bu kurallar olmadan paketler düşürülür.
# Risk: Düşük — sadece vmbr1 subnet'inden çıkan trafiğe izin verir.
```

Test edin (bu adımlardan sonra VM'den ping atın):
```bash
# VM içinde:
ping -c 3 8.8.8.8
curl -s --max-time 5 http://example.com
```

---

### Adım 2 — Kalıcı Yapılandırma (`/etc/network/interfaces`)

Eğer Adım 1 çalıştıysa, kuralları kalıcı hale getirin:

```bash
# Mevcut dosyayı yedekleyin
cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%Y%m%d)
```

`/etc/network/interfaces` dosyasındaki vmbr1 bloğunu şu şekilde güncelleyin:

```
auto vmbr1
iface vmbr1 inet static
    address 10.10.1.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '10.10.1.0/24' -o vmbr0 -j MASQUERADE
    post-up   iptables -A FORWARD -s '10.10.1.0/24' -o vmbr0 -j ACCEPT
    post-up   iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    post-down iptables -t nat -D POSTROUTING -s '10.10.1.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -D FORWARD -s '10.10.1.0/24' -o vmbr0 -j ACCEPT
```

```bash
# [CONFIG CHANGE] sysctl ile ip_forward'u kalıcı yap
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
sysctl -p
```

**Not:** `vmbr0` yerine gerçek public interface adınızı kullanın. Bunu `ip route show default` ile öğrenebilirsiniz — `dev` kısmından sonraki değer doğru interface adıdır.

---

### Rollback (Bir şey ters giderse)

```bash
# Tüm iptables kurallarını sıfırla
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
```

---

## Phase 4 — Doğrulama Komutları

Düzeltmeyi uyguladıktan sonra şu testleri yapın:

```bash
# 1. IP forwarding doğrula
cat /proc/sys/net/ipv4/ip_forward
# Beklenen: 1

# 2. NAT kuralının eklendiğini doğrula
sudo iptables -t nat -L POSTROUTING -n -v
# Beklenen: MASQUERADE kuralı 10.10.1.0/24 için görünmeli

# 3. FORWARD kurallarını doğrula
sudo iptables -L FORWARD -n -v --line-numbers
# Beklenen: ACCEPT kuralı -s 10.10.1.0/24 -o vmbr0 için görünmeli

# 4. VM içinden gateway ping
ping -c 3 10.10.1.1
# Beklenen: 0% packet loss

# 5. VM içinden internet ping (IP düzeyinde)
ping -c 3 8.8.8.8
# Beklenen: 0% packet loss — bu çalışıyorsa routing + NAT tamam

# 6. VM içinden DNS doğrulama
ping -c 3 google.com
# Beklenen: Çözümlenip ping atılmalı (DNS çalışıyor)

# 7. VM içinden HTTP erişim testi
curl -s --max-time 10 http://example.com | head -5
# Beklenen: HTML içeriği dönmeli

# 8. Paket sayaçlarını kontrol et (NAT gerçekten kullanılıyor mu?)
sudo iptables -t nat -L POSTROUTING -n -v
# Beklenen: pkts/bytes sütununda artış olmalı
```

---

## Özet — Ne Oldu, Ne Yapıldı

| Sorun | Neden Oldu | Çözüm |
|-------|------------|-------|
| IP forwarding kapalı | Varsayılan Linux davranışı, NAT bridge kurulumunda etkinleştirilmemiş | `echo 1 > /proc/sys/net/ipv4/ip_forward` + sysctl kalıcı ayar |
| MASQUERADE kuralı yok | `/etc/network/interfaces` post-up hook'ları eksik | `iptables -t nat -A POSTROUTING -s 10.10.1.0/24 -o vmbr0 -j MASQUERADE` |
| FORWARD zinciri engeli | iptables varsayılan DROP politikası | `iptables -A FORWARD -s 10.10.1.0/24 -o vmbr0 -j ACCEPT` |
| Kalıcılık eksikliği | Kurallar reboot'ta kayboluyor | post-up hooks `/etc/network/interfaces`'e eklendi |
