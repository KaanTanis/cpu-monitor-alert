# CPU Monitor - Telegram Bildirimleri

CPU kullanımı belirli bir eşik değerini aştığında detaylı rapor gönderen basit monitoring aracı.

## Özellikler

- CPU kullanımını sürekli izler
- Eşik değeri aşıldığında detaylı rapor gönderir
- Telegram bot üzerinden bildirim
- Secret key ile güvenli abonelik

## Kurulum

### 1. Gereksinimler

```bash
# jq kurulumu (JSON parsing için)
# macOS
brew install jq

# Linux
sudo apt-get install jq
```

### 2. Yapılandırma

`cpu-monitor.sh` dosyasını düzenleyin:

```bash
# Telegram bot token'ınızı ekleyin
TELEGRAM_BOT_TOKEN="your_bot_token_here"

# Secret key'i değiştirin (abonelik için)
SECRET_KEY="your_secret_key_here"

# CPU eşik değeri (varsayılan: 95%)
CPU_THRESHOLD=95

# Kontrol aralığı saniye (varsayılan: 10)
CHECK_INTERVAL=10
```

### 3. Çalıştırma

```bash
# Çalıştırma izni ver
chmod +x cpu-monitor.sh

# Çalıştır
./cpu-monitor.sh
```

### 4. Systemd Servisi (Opsiyonel)

```bash
# Servis dosyası oluştur
sudo nano /etc/systemd/system/cpu-monitor.service
```

İçeriği:

```ini
[Unit]
Description=CPU Monitor with Telegram Alerts
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/path/to/cpu-monitor-alert
ExecStart=/bin/bash /path/to/cpu-monitor-alert/cpu-monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Servisi başlat:

```bash
sudo systemctl daemon-reload
sudo systemctl enable cpu-monitor
sudo systemctl start cpu-monitor
sudo systemctl status cpu-monitor
```

## Kullanım

### Abone Olma

Telegram'da botunuzu açın ve secret key ile abone olun:

```
/start your_secret_key_here
```

veya

```
/your_secret_key_here
```

### Rapor İçeriği

CPU eşik değeri aşıldığında gönderilen rapor şunları içerir:

- Sistem bilgileri
- CPU ve process bilgileri
- Bellek kullanımı
- Disk kullanımı
- Ağ bağlantıları
- Sistem logları
- Çalışan servisler

## Yapılandırma

### Değişkenler

- `CPU_THRESHOLD`: CPU eşik değeri (yüzde)
- `CHECK_INTERVAL`: Kontrol aralığı (saniye)
- `SECRET_KEY`: Abonelik için secret key
- `TELEGRAM_BOT_TOKEN`: Telegram bot token'ı

### Loglar

Loglar `/var/log/cpu-monitor/monitor.log` dosyasına kaydedilir.

Raporlar `/var/log/cpu-monitor/cpu_report_*.txt` dosyalarına kaydedilir.

## Sorun Giderme

### Bot Token Kontrolü

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getMe" | jq .
```

### Log Kontrolü

```bash
tail -f /var/log/cpu-monitor/monitor.log
```

### Servis Durumu

```bash
sudo systemctl status cpu-monitor
sudo journalctl -u cpu-monitor -f
```

## Güvenlik

- Secret key'i güçlü tutun
- Bot token'ını güvenli saklayın
- Script'i root olarak çalıştırın (sistem bilgileri için gerekli)

## Lisans

MIT License
