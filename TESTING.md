# Telegram Bot Test ve Sorun Giderme Rehberi

## Yapılan Düzeltmeler

1. ✅ Gelişmiş hata yakalama ve loglama
2. ✅ Başlangıçta bot token testi
3. ✅ Curl hata kontrolleri
4. ✅ JSON yanıt doğrulama
5. ✅ Offset yönetimi iyileştirmeleri
6. ✅ `/start` komutu bot kullanıcı adı desteği

## Kontrol Listesi

### 1. Bot Token Kontrolü

```bash
# Token'ın dolu olduğundan emin olun
grep "TELEGRAM_BOT_TOKEN=" cpu-monitor.sh

# Token'ı test edin
TOKEN="YOUR_BOT_TOKEN"
curl -s "https://api.telegram.org/bot${TOKEN}/getMe" | jq .
```

**Beklenen çıktı:**
```json
{
  "ok": true,
  "result": {
    "id": 123456789,
    "is_bot": true,
    "first_name": "Bot Name",
    "username": "bot_username"
  }
}
```

### 2. jq Kurulumu

```bash
# macOS
brew install jq

# Linux (Ubuntu/Debian)
sudo apt-get install jq

# Linux (CentOS/RHEL)
sudo yum install jq
```

### 3. Script Çalıştırma

```bash
# Test modunda çalıştır (foreground)
bash cpu-monitor.sh

# Veya systemd servisi olarak
sudo systemctl start cpu-monitor
sudo systemctl status cpu-monitor
```

### 4. Log Kontrolü

```bash
# Log dosyasını kontrol et
tail -f /var/log/cpu-monitor/monitor.log

# Systemd logları
sudo journalctl -u cpu-monitor -f
```

### 5. Telegram Bot Testi

1. Telegram'da botunuzu açın
2. `/start` komutunu gönderin
3. Log dosyasını kontrol edin:
   - "Start komutu alındı" mesajı görünmeli
   - "Start mesajı başarıyla gönderildi" mesajı görünmeli

### 6. Offset Sıfırlama (Gerekirse)

Eğer offset dosyası bozulmuşsa:

```bash
# Offset dosyasını sıfırla
echo "0" > /var/log/cpu-monitor/last_offset.txt

# Script'i yeniden başlat
sudo systemctl restart cpu-monitor
```

## Yaygın Sorunlar ve Çözümleri

### Sorun: "TELEGRAM_BOT_TOKEN boş!" hatası

**Çözüm:**
```bash
# cpu-monitor.sh dosyasını düzenle
nano cpu-monitor.sh

# TELEGRAM_BOT_TOKEN satırını bulun ve token'ı ekleyin
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
```

### Sorun: "jq bulunamadı" hatası

**Çözüm:**
```bash
# jq'yu yükleyin (yukarıdaki kurulum talimatlarına bakın)
brew install jq  # macOS
# veya
sudo apt-get install jq  # Linux
```

### Sorun: "Telegram API hatası: Unauthorized"

**Çözüm:**
- Bot token'ının doğru olduğundan emin olun
- Token'ı BotFather'dan yeniden alın
- Token'da gereksiz boşluk olmadığından emin olun

### Sorun: "/start" komutuna yanıt gelmiyor

**Kontrol Listesi:**
1. ✅ Script çalışıyor mu? (`ps aux | grep cpu-monitor`)
2. ✅ Token doğru mu? (`curl` ile test edin)
3. ✅ jq kurulu mu? (`which jq`)
4. ✅ Log dosyasında hata var mı? (`tail -f /var/log/cpu-monitor/monitor.log`)
5. ✅ Offset dosyası doğru mu? (`cat /var/log/cpu-monitor/last_offset.txt`)

### Sorun: Mesajlar alınıyor ama yanıt gönderilemiyor

**Kontrol:**
```bash
# Bot'un kullanıcıya mesaj gönderme izni var mı?
# Bot'u engellemiş olabilirsiniz - Telegram'da kontrol edin

# Log dosyasında "Mesaj gönderilemedi" hatası var mı?
grep "Mesaj gönderilemedi" /var/log/cpu-monitor/monitor.log
```

## Debug Modu

Daha detaylı loglar için script'i manuel olarak çalıştırın:

```bash
# Script'i foreground'da çalıştır
bash -x cpu-monitor.sh 2>&1 | tee debug.log
```

## Test Senaryosu

1. **Bot Token'ı Ayarlayın:**
   ```bash
   # cpu-monitor.sh dosyasını düzenle
   TELEGRAM_BOT_TOKEN="YOUR_TOKEN_HERE"
   ```

2. **Script'i Başlatın:**
   ```bash
   bash cpu-monitor.sh
   ```

3. **Beklenen Log Çıktısı:**
   ```
   [2024-01-01 12:00:00] CPU Monitor başlatılıyor (Eşik: 95%)
   [2024-01-01 12:00:00] Telegram bot bağlantısı test ediliyor...
   [2024-01-01 12:00:01] ✓ Telegram bot bağlantısı başarılı: @bot_username (Bot Name)
   [2024-01-01 12:00:01] Mevcut offset: 0
   [2024-01-01 12:00:01] Monitoring başlatıldı. Telegram mesajları dinleniyor...
   ```

4. **Telegram'da /start Gönderin:**
   - Log'da şunları görmelisiniz:
   ```
   [2024-01-01 12:00:10] Telegram update alındı: 1 adet (offset: 0)
   [2024-01-01 12:00:10] Mesaj işleniyor: update_id=123, chat_id=456, text=/start
   [2024-01-01 12:00:10] Start komutu alındı: chat_id=456, text=/start
   [2024-01-01 12:00:11] ✓ Start mesajı başarıyla gönderildi: chat_id=456
   ```

## İletişim

Sorun devam ederse:
1. Log dosyasını kontrol edin: `/var/log/cpu-monitor/monitor.log`
2. Systemd loglarını kontrol edin: `sudo journalctl -u cpu-monitor -n 50`
3. Bot token'ını test edin: `curl -s "https://api.telegram.org/bot<TOKEN>/getMe" | jq .`

