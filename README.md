# 🚀 CPU Monitor - Telegram Bildirim Sistemi

CPU kullanımı belirli bir yüzdeyi aştığında Telegram botuna otomatik bildirim gönderen basit ve etkili bir monitoring aracı.

## ✨ Özellikler

- ✅ **Gerçek Zamanlı CPU İzleme** - Yapılandırılabilir eşik değeri ile sürekli izleme
- 📱 **Telegram Bildirimleri** - HTML formatlı anlık uyarılar
- 🔐 **Şifre Korumalı Abonelik** - Sadece şifreyi bilenler abone olabilir
- 📊 **Detaylı Raporlar** - CPU spike durumunda otomatik diagnostic raporu
- 🛡️ **Çoklu Kullanıcı Desteği** - Sınırsız abone
- ⏱️ **Akıllı Uyarı Sistemi** - 3 kez üst üste yüksek CPU tespit edilince uyarı (yanlış alarm önleme)
- 📁 **Rapor Arşivi** - Tüm raporlar zaman damgası ile kaydedilir

## 📋 Gereksinimler

- Linux sunucu (Ubuntu/Debian önerilir)
- Bash 4.0+
- systemd
- curl
- jq (JSON parsing için)
- Telegram Bot Token

## 🚀 Kurulum

### 1. Telegram Bot Oluşturma

1. Telegram'da [@BotFather](https://t.me/BotFather) ile konuşun
2. `/newbot` komutunu gönderin
3. Bot adını ve kullanıcı adını belirleyin
4. Verilen **Bot Token**'ı kopyalayın

### 2. Dosyaları Sunucuya Yükleme

**Git ile kurulum (önerilen):**

```bash
# Sunucuda klasör oluştur ve git clone yap
sudo mkdir -p /usr/local/bin
cd /usr/local/bin
sudo git clone <REPO_URL> cpu-monitor-alert
# veya mevcut klasörde ise:
cd /usr/local/bin/cpu-monitor-alert
sudo git pull
```

**Manuel kurulum:**

```bash
# Sunucuda klasör oluştur
sudo mkdir -p /usr/local/bin/cpu-monitor-alert
cd /usr/local/bin/cpu-monitor-alert

# Dosyaları buraya kopyalayın:
# - cpu-monitor.sh
# - telegram_password.txt
# - README.md
```

### 3. Yapılandırma

```bash
# cpu-monitor.sh dosyasını düzenle
sudo nano /usr/local/bin/cpu-monitor-alert/cpu-monitor.sh

# TELEGRAM_BOT_TOKEN değişkenine bot token'ınızı ekleyin:
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"

# İsteğe bağlı: CPU eşik değerini değiştirin (varsayılan: 95%)
CPU_THRESHOLD=95

# İsteğe bağlı: Kontrol aralığını değiştirin (varsayılan: 10 saniye)
CHECK_INTERVAL=10
```

### 4. Şifre Ayarlama

```bash
# telegram_password.txt dosyasını düzenle
sudo nano /usr/local/bin/cpu-monitor-alert/telegram_password.txt

# İstediğiniz şifreyi yazın (varsayılan: 1234)
# Örnek: mySecurePassword123
```

### 5. Çalıştırma İzinleri

```bash
# Script'e çalıştırma izni ver
sudo chmod +x /usr/local/bin/cpu-monitor-alert/cpu-monitor.sh

# Şifre dosyasını korumalı yap
sudo chmod 600 /usr/local/bin/cpu-monitor-alert/telegram_password.txt
```

### 6. Systemd Servisi Oluşturma

```bash
# Servis dosyası oluştur
sudo nano /etc/systemd/system/cpu-monitor.service
```

Aşağıdaki içeriği yapıştırın:

```ini
[Unit]
Description=CPU Monitor with Telegram Alerts
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin/cpu-monitor-alert
ExecStart=/bin/bash /usr/local/bin/cpu-monitor-alert/cpu-monitor.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 7. Servisi Başlatma

```bash
# Systemd'yi yeniden yükle
sudo systemctl daemon-reload

# Servisi etkinleştir (otomatik başlatma)
sudo systemctl enable cpu-monitor

# Servisi başlat
sudo systemctl start cpu-monitor

# Durumu kontrol et
sudo systemctl status cpu-monitor
```

## 📱 Kullanım

### Abone Olma

1. Telegram botunuzu açın
2. `/start` komutunu gönderin
3. Bot size şifre soracak
4. `/password ŞİFRENİZ` komutunu gönderin (örnek: `/password 1234`)
5. Şifre doğruysa "✅ Başarılı!" mesajı alacaksınız

### Komutlar

| Komut | Açıklama |
|-------|----------|
| `/start` | Abonelik başlat (şifre sorar) |
| `/password ŞİFRE` | Şifre girerek abone ol |
| `/status` | Mevcut CPU durumunu göster |

### Bildirim Örneği

CPU eşik değerini aştığında şu bilgileri içeren bir mesaj alırsınız:
- Sunucu adı
- Zaman
- CPU kullanımı
- Load average
- Bellek kullanımı
- En çok CPU kullanan processler
- Detaylı diagnostic raporu (dosya olarak)

## ⚙️ Yapılandırma Seçenekleri

### cpu-monitor.sh İçinde

```bash
# CPU eşik değeri (yüzde)
CPU_THRESHOLD=95

# Kontrol aralığı (saniye)
CHECK_INTERVAL=10

# Log dizini
LOG_DIR="/var/log/cpu-monitor"

# Aboneler dosyası
SUBSCRIBERS_FILE="/var/log/cpu-monitor/subscribers.txt"

# Şifre dosyası (otomatik olarak script dizininde aranır)
PASSWORD_FILE="/usr/local/bin/cpu-monitor-alert/telegram_password.txt"
```

### Uyarı Cooldown

Uyarılar spam'i önlemek için **5 dakikada bir** gönderilir.

### Uyarı Mantığı

- CPU eşik değerini 3 kez üst üste aşarsa uyarı gönderilir
- Son uyarıdan 5 dakika geçmeden yeni uyarı gönderilmez

## 📊 Loglar ve Raporlar

### Logları Görüntüleme

```bash
# Canlı loglar
sudo journalctl -u cpu-monitor -f

# Son 100 satır
sudo journalctl -u cpu-monitor -n 100

# Bugünkü loglar
sudo journalctl -u cpu-monitor --since today
```

### Monitor Logları

```bash
# Monitor aktivite logu
sudo tail -f /var/log/cpu-monitor/monitor.log

# Diagnostic raporlarını listele
sudo ls -lh /var/log/cpu-monitor/diagnostic_*.txt

# En son raporu görüntüle
sudo cat $(sudo ls -t /var/log/cpu-monitor/diagnostic_*.txt | head -1)
```

## 🔧 Sorun Giderme

### Servis Başlamıyor

```bash
# Sözdizimi kontrolü
bash -n /usr/local/bin/cpu-monitor-alert/cpu-monitor.sh

# İzinleri kontrol et
ls -la /usr/local/bin/cpu-monitor-alert/cpu-monitor.sh
sudo chmod +x /usr/local/bin/cpu-monitor-alert/cpu-monitor.sh

# Logları kontrol et
sudo journalctl -u cpu-monitor -n 50
```

### Bildirim Gelmiyor

```bash
# Bot token'ı kontrol et
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"

# Aboneleri kontrol et
sudo cat /var/log/cpu-monitor/subscribers.txt

# jq kurulu mu kontrol et
which jq
# Kurulu değilse: sudo apt-get install jq
```

### Şifre Çalışmıyor

```bash
# Şifre dosyasını kontrol et
sudo cat /usr/local/bin/cpu-monitor-alert/telegram_password.txt

# İzinleri kontrol et
ls -la /usr/local/bin/cpu-monitor-alert/telegram_password.txt

# Dosya boşsa varsayılan şifre: 1234
```

## 🔒 Güvenlik

- ✅ Bot token yerel dosyada saklanır (Git'te değil)
- ✅ Şifre korumalı abonelik sistemi
- ✅ Root olarak çalışır (sistem operasyonları için gerekli)
- ✅ Abone listesi yerel olarak saklanır
- ⚠️ Bot token'ınızı şifre gibi koruyun
- ⚠️ Şifre dosyasını sadece root erişebilecek şekilde ayarlayın

### Önerilen İzinler

```bash
# Script dosyası
sudo chmod 755 /usr/local/bin/cpu-monitor-alert/cpu-monitor.sh

# Şifre dosyası (sadece root)
sudo chmod 600 /usr/local/bin/cpu-monitor-alert/telegram_password.txt

# Aboneler dosyası (sadece root)
sudo chmod 600 /var/log/cpu-monitor/subscribers.txt
```

## 📈 Performans Etkisi

- **CPU Kullanımı**: < 0.1% (normal çalışmada)
- **Bellek**: ~5-10 MB
- **Disk**: Diagnostic raporları ~50-100 KB (her rapor)
- **Network**: Minimal (sadece uyarılar sırasında)

## 🎯 Kullanım Senaryoları

- **Web Hosting Sağlayıcıları** - Müşteri sunucularını izleme
- **DevOps Ekipleri** - Production sunucular için gerçek zamanlı uyarı
- **Sistem Yöneticileri** - Proaktif sunucu izleme
- **Küçük İşletmeler** - Uygun maliyetli izleme çözümü
- **Kişisel Projeler** - VPS/Cloud sunucularını sağlıklı tutma

## 📝 Dosya Yapısı

```
/usr/local/bin/cpu-monitor-alert/
├── cpu-monitor.sh              # Ana monitoring scripti
├── telegram_password.txt       # Abonelik şifresi
└── README.md                   # Dokümantasyon

/var/log/cpu-monitor/
├── monitor.log                 # Aktivite logları
├── subscribers.txt             # Abone listesi
├── last_offset.txt             # Telegram update offset
└── diagnostic_*.txt            # Diagnostic raporları
```

## 🔄 Güncelleme

```bash
# Servisi durdur
sudo systemctl stop cpu-monitor

# Git ile güncelle (veya yeni dosyaları kopyala)
cd /usr/local/bin/cpu-monitor-alert
sudo git pull

# Servisi başlat
sudo systemctl start cpu-monitor
```

## 📄 Lisans

MIT License
