#!/bin/bash

##############################################
# CPU Monitor - Telegram Bildirimleri
# CPU eşik değerini aştığında detaylı rapor gönderir
##############################################

# Script dizinini belirle
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

# Varsayılan değerler
DEFAULT_CPU_THRESHOLD=95
DEFAULT_CHECK_INTERVAL=10
DEFAULT_CONSECUTIVE_CHECKS=3
DEFAULT_ALERT_INTERVAL=300
DEFAULT_LOG_RETENTION_DAYS=7
DEFAULT_SECRET_KEY="your_secret_key_here"
DEFAULT_TELEGRAM_BOT_TOKEN=""

# Config dosyasını oluştur veya oku
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# CPU Monitor Konfigürasyonu
# Bu dosyayı düzenleyerek ayarları değiştirebilirsiniz

# Telegram Bot Token (zorunlu)
TELEGRAM_BOT_TOKEN=$DEFAULT_TELEGRAM_BOT_TOKEN

# Abonelik için gizli anahtar (zorunlu - mutlaka değiştirin!)
SECRET_KEY=$DEFAULT_SECRET_KEY

# CPU eşik değeri (%)
CPU_THRESHOLD=$DEFAULT_CPU_THRESHOLD

# Kontrol aralığı (saniye)
CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL

# Arka arkaya kaç kez eşiği geçerse uyarı versin
CONSECUTIVE_CHECKS=$DEFAULT_CONSECUTIVE_CHECKS

# Uyarılar arası minimum süre (saniye) - Eşik geçildiği sürece bu süre sonunda yeni rapor gönderir
ALERT_INTERVAL=$DEFAULT_ALERT_INTERVAL

# Log dosyalarını kaç gün saklasın
LOG_RETENTION_DAYS=$DEFAULT_LOG_RETENTION_DAYS
EOF
    echo "Varsayılan config dosyası oluşturuldu: $CONFIG_FILE"
    echo "Lütfen TELEGRAM_BOT_TOKEN ve SECRET_KEY değerlerini düzenleyin!"
}

# Config dosyasını yükle
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        create_default_config
        exit 1
    fi
    
    # Config dosyasını source et
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    # Zorunlu değerleri kontrol et
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ "$TELEGRAM_BOT_TOKEN" = "$DEFAULT_TELEGRAM_BOT_TOKEN" ]; then
        echo "HATA: TELEGRAM_BOT_TOKEN ayarlanmamış!"
        echo "Lütfen $CONFIG_FILE dosyasını düzenleyin."
        exit 1
    fi
    
    if [ -z "$SECRET_KEY" ] || [ "$SECRET_KEY" = "$DEFAULT_SECRET_KEY" ]; then
        echo "HATA: SECRET_KEY varsayılan değerde!"
        echo "Lütfen $CONFIG_FILE dosyasında SECRET_KEY değerini değiştirin."
        exit 1
    fi
    
    # Varsayılan değerleri ata (config'de yoksa)
    CPU_THRESHOLD=${CPU_THRESHOLD:-$DEFAULT_CPU_THRESHOLD}
    CHECK_INTERVAL=${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}
    CONSECUTIVE_CHECKS=${CONSECUTIVE_CHECKS:-$DEFAULT_CONSECUTIVE_CHECKS}
    ALERT_INTERVAL=${ALERT_INTERVAL:-$DEFAULT_ALERT_INTERVAL}
    LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-$DEFAULT_LOG_RETENTION_DAYS}
}

# Config'i yükle
load_config

# Dizinler
[ "$(uname)" = "Darwin" ] && LOG_DIR="$SCRIPT_DIR/logs" || LOG_DIR="/var/log/cpu-monitor"
SUBSCRIBERS_FILE="$LOG_DIR/subscribers.txt"
LAST_OFFSET_FILE="$LOG_DIR/last_offset.txt"

# Dizinleri oluştur
mkdir -p "$LOG_DIR"
touch "$SUBSCRIBERS_FILE" "$LAST_OFFSET_FILE" 2>/dev/null

# Log fonksiyonu
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/monitor.log" 2>/dev/null
}

# Eski logları temizle
cleanup_old_logs() {
    if [ -d "$LOG_DIR" ]; then
        find "$LOG_DIR" -name "cpu_report_*.txt" -type f -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null
        # Monitor log'unu da temizle (son X günü tut)
        if [ -f "$LOG_DIR/monitor.log" ]; then
            tail -n 10000 "$LOG_DIR/monitor.log" > "$LOG_DIR/monitor.log.tmp" 2>/dev/null
            mv "$LOG_DIR/monitor.log.tmp" "$LOG_DIR/monitor.log" 2>/dev/null
        fi
    fi
}

# Telegram mesaj gönder
send_telegram() {
    local message="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ ! -s "$SUBSCRIBERS_FILE" ] && return 1
    
    while IFS= read -r chat_id; do
        [ -z "$chat_id" ] && continue
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$chat_id" \
            -d text="$message" \
            -d parse_mode="HTML" >/dev/null 2>&1
    done < "$SUBSCRIBERS_FILE"
}

# Telegram'a dosya gönder
send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ ! -f "$file_path" ] || [ ! -s "$SUBSCRIBERS_FILE" ] && return 1
    
    while IFS= read -r chat_id; do
        [ -n "$chat_id" ] && curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="$chat_id" \
            -F document=@"$file_path" \
            -F caption="$caption" >/dev/null 2>&1
    done < "$SUBSCRIBERS_FILE"
}

# CPU kullanımını al
get_cpu_usage() {
    if [ "$(uname)" = "Darwin" ]; then
        top -l 1 | grep "CPU usage" | awk '{print $3}' | sed 's/%//'
    else
        top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}'
    fi
}

# Detaylı rapor oluştur
create_report() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local report_file="$LOG_DIR/cpu_report_${timestamp}.txt"
    local cpu_usage="$1"
    
    {
        echo "--- TOP 20 REQUEST IP (nginx) ---"
        grep -h "" /var/log/nginx/*access.log 2>/dev/null | \
        awk '{print $1}' | sort | uniq -c | sort -nr | head -20
        echo ""
        echo "--- TOP 20 REQUESTED URL ---"
        grep -h "" /var/log/nginx/*access.log 2>/dev/null | \
        awk '{print $7}' | sort | uniq -c | sort -nr | head -20
        echo ""
        echo "--- TOP USER AGENTS ---"
        grep -h "" /var/log/nginx/*access.log 2>/dev/null | \
        awk -F\" '{print $6}' | sort | uniq -c | sort -nr | head -20
        echo ""
        echo "--- 404 COUNT (last 10000 lines) ---"
        tail -n 10000 /var/log/nginx/access.log 2>/dev/null | \
        grep " 404 " | wc -l
        echo ""
        echo "--- PHP-FPM PROCESS COUNT ---"
        ps aux | grep php-fpm | grep -v grep | wc -l
        echo ""
        echo "--- SUSPICIOUS IPs (>1000 req) ---"
        grep -h "" /var/log/nginx/*access.log 2>/dev/null | \
        awk '{print $1}' | sort | uniq -c | awk '$1 > 1000' | sort -nr
        echo "=========================================="
        echo "CPU SPIKE REPORT"
        echo "Time: $(date)"
        echo "Hostname: $(hostname)"
        echo "CPU Usage: ${cpu_usage}%"
        echo "Threshold: ${CPU_THRESHOLD}%"
        echo "=========================================="
        echo ""
        echo "--- SYSTEM INFO ---"
        uname -a
        echo ""
        echo "--- UPTIME & LOAD AVERAGE ---"
        uptime
        echo ""
        echo "--- CPU INFO ---"
        if [ "$(uname)" = "Darwin" ]; then
            top -l 1 | head -20
        else
            top -bn1 | head -20
        fi
        echo ""
        echo "--- TOP 20 CPU CONSUMING PROCESSES ---"
        ps aux --sort=-%cpu | head -21
        echo ""
        echo "--- MEMORY USAGE ---"
        if [ "$(uname)" = "Darwin" ]; then
            vm_stat
            sysctl hw.memsize
        else
            free -h
            cat /proc/meminfo 2>/dev/null | head -20
        fi
        echo ""
        echo "--- DISK USAGE ---"
        df -h
        echo ""
        echo "--- DISK I/O ---"
        iostat -x 1 1 2>/dev/null || echo "iostat not available"
        echo ""
        echo "--- NETWORK CONNECTIONS ---"
        netstat -tunap 2>/dev/null | head -30 || ss -tunap 2>/dev/null | head -30
        echo ""
        echo "--- NETWORK STATS ---"
        ifconfig 2>/dev/null | head -50 || ip addr show 2>/dev/null | head -50
        echo ""
        echo "--- SYSTEM LOGS (last 20 lines) ---"
        tail -20 /var/log/syslog 2>/dev/null || tail -20 /var/log/messages 2>/dev/null || echo "System logs not available"
        echo ""
        echo "--- RUNNING SERVICES ---"
        systemctl list-units --type=service --state=running 2>/dev/null | head -30 || service --status-all 2>/dev/null | head -30
        echo ""
        echo "=========================================="
    } > "$report_file"
    
    echo "$report_file"
}

# Telegram mesajlarını işle
process_telegram_updates() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 1
    ! command -v jq >/dev/null 2>&1 && return 1
    
    local last_offset=$(cat "$LAST_OFFSET_FILE" 2>/dev/null || echo "0")
    [ -z "$last_offset" ] && last_offset="0"
    
    local updates=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$last_offset&timeout=5" 2>&1)
    
    [ -z "$updates" ] || ! echo "$updates" | jq -e '.ok == true' >/dev/null 2>&1 && return 1
    
    local update_count=$(echo "$updates" | jq '.result | length' 2>/dev/null)
    [ -z "$update_count" ] || [ "$update_count" = "0" ] && return 0
    
    # Tüm update_id'leri topla
    local max_update_id=$(echo "$updates" | jq -r '[.result[].update_id] | max // 0' 2>/dev/null)
    [ -z "$max_update_id" ] && max_update_id="0"
    
    local temp_file=$(mktemp)
    
    echo "$updates" | jq -r '.result[]? | 
        if .message then
            "\(.update_id)|\(.message.chat.id // "")|\(.message.text // "")"
        elif .edited_message then
            "\(.update_id)|\(.edited_message.chat.id // "")|\(.edited_message.text // "")"
        else empty end' > "$temp_file" 2>/dev/null
    
    if [ -s "$temp_file" ]; then
        while IFS='|' read -r update_id chat_id text; do
            [ -z "$update_id" ] || [ -z "$chat_id" ] || [ -z "$text" ] && continue
            
            # Secret key ile abonelik
            if [ "$text" = "/${SECRET_KEY}" ] || [ "$text" = "/start ${SECRET_KEY}" ]; then
                if ! grep -q "^${chat_id}$" "$SUBSCRIBERS_FILE" 2>/dev/null; then
                    echo "$chat_id" >> "$SUBSCRIBERS_FILE"
                    log "Yeni abone: $chat_id"
                    
                    local response="✅ Abone oldunuz!

📊 <b>Ayarlar:</b>
• CPU Eşik: ${CPU_THRESHOLD}%
• Kontrol Sayısı: ${CONSECUTIVE_CHECKS}x
• Kontrol Aralığı: ${CHECK_INTERVAL}s
• Bildirim Aralığı: ${ALERT_INTERVAL}s

ℹ️ CPU ${CONSECUTIVE_CHECKS} kez üst üste ${CPU_THRESHOLD}% üzerine çıktığında bildirim alacaksınız. Eşik aşıldığı sürece her ${ALERT_INTERVAL} saniyede bir yeni rapor gönderilecek."
                    
                    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                        -d chat_id="$chat_id" \
                        -d text="$response" \
                        -d parse_mode="HTML" >/dev/null 2>&1
                else
                    log "Zaten abone: $chat_id (tekrar istek)"
                fi
            fi
        done < "$temp_file"
    fi
    
    rm -f "$temp_file"
    
    # Offset'i her zaman güncelle (mesaj olsun olmasın)
    if [ -n "$max_update_id" ] && [ "$max_update_id" != "0" ]; then
        local new_offset=$((max_update_id + 1))
        echo "$new_offset" > "$LAST_OFFSET_FILE"
    fi
    
    return 0
}

# Ana monitoring döngüsü
main() {
    log "CPU Monitor başlatıldı"
    log "Eşik: ${CPU_THRESHOLD}% | Kontrol: ${CONSECUTIVE_CHECKS}x | Aralık: ${CHECK_INTERVAL}s | Bildirim: ${ALERT_INTERVAL}s | Log Saklama: ${LOG_RETENTION_DAYS} gün"
    
    local consecutive_high=0
    local last_alert_time=0
    local last_cleanup_day=$(date +%d)
    
    while true; do
        process_telegram_updates
        
        # Günlük log temizliği (günde bir kez)
        local current_day=$(date +%d)
        if [ "$current_day" != "$last_cleanup_day" ]; then
            cleanup_old_logs
            last_cleanup_day=$current_day
            log "Eski loglar temizlendi (>${LOG_RETENTION_DAYS} gün)"
        fi
        
        local cpu_usage=$(get_cpu_usage)
        local cpu_usage_int=${cpu_usage%.*}
        
        if [ "$cpu_usage_int" -ge "$CPU_THRESHOLD" ]; then
            consecutive_high=$((consecutive_high + 1))
            log "CPU yüksek: ${cpu_usage}% (${consecutive_high}/${CONSECUTIVE_CHECKS})"
            
            # Eşik sayısına ulaşıldı mı?
            if [ $consecutive_high -ge $CONSECUTIVE_CHECKS ]; then
                local current_time=$(date +%s)
                local time_since_alert=$((current_time - last_alert_time))
                
                # İlk uyarı veya belirlenen süre geçti mi?
                if [ $last_alert_time -eq 0 ] || [ $time_since_alert -ge $ALERT_INTERVAL ]; then
                    local report_file=$(create_report "$cpu_usage")
                    local alert_msg="🚨 <b>CPU Uyarısı</b>

📊 CPU Kullanımı: <b>${cpu_usage}%</b>
⚠️ Eşik: ${CPU_THRESHOLD}%
🔄 Üst üste: ${consecutive_high}x
⏰ Zaman: $(date '+%H:%M:%S')

💾 Detaylı rapor dosya olarak gönderiliyor..."
                    
                    send_telegram "$alert_msg"
                    send_telegram_file "$report_file" "📄 CPU Raporu - $(date '+%Y-%m-%d %H:%M:%S')"
                    
                    log "⚠️  Uyarı gönderildi: CPU ${cpu_usage}% (${consecutive_high}x) - Rapor: $(basename $report_file)"
                    last_alert_time=$current_time
                fi
                # consecutive_high'ı sıfırlama! Eşik geçildiği sürece rapor gönderilmeye devam etsin
            fi
        else
            # CPU normale döndü
            if [ $consecutive_high -gt 0 ]; then
                log "✓ CPU normale döndü: ${cpu_usage}% (önceki: ${consecutive_high}x yüksek)"
                consecutive_high=0
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
}

main
