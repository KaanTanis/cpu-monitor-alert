#!/bin/bash

# Telegram Bot Test Script
# Bu script bot token'ınızın çalışıp çalışmadığını test eder

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPU_MONITOR_SCRIPT="$SCRIPT_DIR/cpu-monitor.sh"

echo "=========================================="
echo "Telegram Bot Test Script"
echo "=========================================="
echo ""

# 1. Token kontrolü
echo "1. Token kontrolü..."
TOKEN=$(grep "^TELEGRAM_BOT_TOKEN=" "$CPU_MONITOR_SCRIPT" | cut -d'"' -f2)

if [ -z "$TOKEN" ]; then
    echo "❌ HATA: TELEGRAM_BOT_TOKEN boş!"
    echo "   Lütfen cpu-monitor.sh dosyasında token'ı ayarlayın."
    exit 1
else
    echo "✓ Token bulundu: ${TOKEN:0:10}..."
fi

echo ""

# 2. jq kontrolü
echo "2. jq kontrolü..."
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ HATA: jq bulunamadı!"
    echo "   macOS: brew install jq"
    echo "   Linux: sudo apt-get install jq"
    exit 1
else
    echo "✓ jq kurulu: $(jq --version)"
fi

echo ""

# 3. Bot bağlantı testi
echo "3. Bot bağlantı testi..."
TEST_RESPONSE=$(curl -s --max-time 10 "https://api.telegram.org/bot${TOKEN}/getMe" 2>&1)

if echo "$TEST_RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
    BOT_USERNAME=$(echo "$TEST_RESPONSE" | jq -r '.result.username // "unknown"' 2>/dev/null)
    BOT_NAME=$(echo "$TEST_RESPONSE" | jq -r '.result.first_name // "unknown"' 2>/dev/null)
    echo "✓ Bot bağlantısı başarılı!"
    echo "   Bot: @$BOT_USERNAME ($BOT_NAME)"
else
    ERROR_CODE=$(echo "$TEST_RESPONSE" | jq -r '.error_code // "unknown"' 2>/dev/null)
    ERROR_DESC=$(echo "$TEST_RESPONSE" | jq -r '.description // "Unknown error"' 2>/dev/null)
    echo "❌ HATA: Bot bağlantısı başarısız!"
    echo "   Error Code: $ERROR_CODE"
    echo "   Error: $ERROR_DESC"
    echo "   Response: $TEST_RESPONSE"
    exit 1
fi

echo ""

# 4. getUpdates testi
echo "4. getUpdates testi..."
UPDATES_RESPONSE=$(curl -s --max-time 10 "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=0&limit=1" 2>&1)

if echo "$UPDATES_RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
    UPDATE_COUNT=$(echo "$UPDATES_RESPONSE" | jq '.result | length' 2>/dev/null)
    echo "✓ getUpdates çalışıyor!"
    echo "   Bekleyen update sayısı: $UPDATE_COUNT"
    
    if [ "$UPDATE_COUNT" -gt 0 ]; then
        echo "   ⚠️  UYARI: Bekleyen update'ler var. Bu normal olabilir."
        echo "   İlk update:"
        echo "$UPDATES_RESPONSE" | jq '.result[0]' 2>/dev/null | head -10
    fi
else
    ERROR_CODE=$(echo "$UPDATES_RESPONSE" | jq -r '.error_code // "unknown"' 2>/dev/null)
    ERROR_DESC=$(echo "$UPDATES_RESPONSE" | jq -r '.description // "Unknown error"' 2>/dev/null)
    echo "❌ HATA: getUpdates başarısız!"
    echo "   Error Code: $ERROR_CODE"
    echo "   Error: $ERROR_DESC"
    exit 1
fi

echo ""

# 5. Log dizini kontrolü
echo "5. Log dizini kontrolü..."
LOG_DIR="/var/log/cpu-monitor"
if [ ! -d "$LOG_DIR" ]; then
    echo "⚠️  UYARI: Log dizini yok: $LOG_DIR"
    echo "   Script çalıştığında otomatik oluşturulacak."
else
    echo "✓ Log dizini mevcut: $LOG_DIR"
    if [ -f "$LOG_DIR/monitor.log" ]; then
        echo "   Son log satırları:"
        tail -5 "$LOG_DIR/monitor.log" | sed 's/^/   /'
    fi
fi

echo ""

# 6. Şifre dosyası kontrolü
echo "6. Şifre dosyası kontrolü..."
PASSWORD_FILE="$SCRIPT_DIR/telegram_password.txt"
if [ -f "$PASSWORD_FILE" ]; then
    echo "✓ Şifre dosyası mevcut: $PASSWORD_FILE"
    echo "   (İçeriği gösterilmiyor - güvenlik)"
else
    echo "⚠️  UYARI: Şifre dosyası yok: $PASSWORD_FILE"
    echo "   Script çalıştığında varsayılan şifre (1234) oluşturulacak."
fi

echo ""

echo "=========================================="
echo "✅ Tüm testler tamamlandı!"
echo "=========================================="
echo ""
echo "Sonraki adımlar:"
echo "1. Telegram'da botunuzu açın"
echo "2. /start komutunu gönderin"
echo "3. Log dosyasını kontrol edin: tail -f $LOG_DIR/monitor.log"
echo ""
echo "Script'i çalıştırmak için:"
echo "  bash cpu-monitor.sh"
echo ""
echo "Veya systemd servisi olarak:"
echo "  sudo systemctl start cpu-monitor"
echo "  sudo systemctl status cpu-monitor"

