#!/bin/bash

##############################################
# CPU Monitor - Telegram Bildirimleri
# CPU belirli yüzdeyi aşarsa Telegram'a bildirim gönderir
##############################################

# Konfigürasyon
CPU_THRESHOLD=95
CHECK_INTERVAL=10
LOG_DIR="/var/log/cpu-monitor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELEGRAM_BOT_TOKEN=""
SUBSCRIBERS_FILE="$LOG_DIR/subscribers.txt"
PASSWORD_FILE="$SCRIPT_DIR/telegram_password.txt"
LAST_OFFSET_FILE="$LOG_DIR/last_offset.txt"

# Dizinleri oluştur
mkdir -p "$LOG_DIR"
touch "$SUBSCRIBERS_FILE"
touch "$LAST_OFFSET_FILE"

# Log fonksiyonu
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/monitor.log"
}

# Telegram mesaj gönder
send_telegram() {
    local message="$1"
    local sent_count=0
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ ! -f "$SUBSCRIBERS_FILE" ] || [ ! -s "$SUBSCRIBERS_FILE" ]; then
        return 1
    fi
    
    while IFS= read -r chat_id; do
        [ -z "$chat_id" ] && continue
        
        local response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$chat_id" \
            -d text="$message" \
            -d parse_mode="HTML")
        
        if echo "$response" | grep -q '"ok":true'; then
            sent_count=$((sent_count + 1))
        elif echo "$response" | grep -q "bot was blocked"; then
            sed -i "/^${chat_id}$/d" "$SUBSCRIBERS_FILE"
            log "Subscriber kaldırıldı (bot blocked): $chat_id"
        fi
    done < "$SUBSCRIBERS_FILE"
    
    [ $sent_count -gt 0 ] && log "Telegram bildirimi gönderildi ($sent_count kişi)"
    return 0
}

# Telegram'a dosya gönder
send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ ! -f "$file_path" ] && return 1
    [ ! -f "$SUBSCRIBERS_FILE" ] || [ ! -s "$SUBSCRIBERS_FILE" ] && return 1
    
    while IFS= read -r chat_id; do
        [ -n "$chat_id" ] && curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="$chat_id" \
            -F document=@"$file_path" \
            -F caption="$caption" >/dev/null 2>&1
    done < "$SUBSCRIBERS_FILE"
}

# CPU kullanımını al
get_cpu_usage() {
    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}'
}

# Şifreyi kontrol et
check_password() {
    local password="$1"
    if [ ! -f "$PASSWORD_FILE" ]; then
        echo "1234" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
    fi
    local stored_password=$(cat "$PASSWORD_FILE" | tr -d '\n\r ')
    [ "$password" = "$stored_password" ]
}

# Telegram mesajlarını işle (PIN kontrolü ile)
process_telegram_updates() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 1
    
    local last_offset=$(cat "$LAST_OFFSET_FILE" 2>/dev/null || echo "0")
    local updates=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$last_offset&timeout=1")
    
    [ -z "$updates" ] && return 1
    
    # jq kullanarak mesajları parse et
    if ! command -v jq >/dev/null 2>&1; then
        log "jq bulunamadı. 'apt-get install jq' veya 'yum install jq' ile yükleyin."
        return 1
    fi
    
    # Process substitution kullanarak max_update_id'yi dışarıda tutabiliriz
    local max_update_id=0
    local temp_file=$(mktemp)
    
    echo "$updates" | jq -r '.result[]? | "\(.update_id)|\(.message.chat.id // "")|\(.message.text // "")"' > "$temp_file"
    
    while IFS='|' read -r update_id chat_id text; do
        [ -z "$update_id" ] && continue
        [ "$update_id" -gt "$max_update_id" ] && max_update_id=$update_id
        [ -z "$chat_id" ] || [ -z "$text" ] && continue
        
        # /start komutu
        if [ "$text" = "/start" ]; then
            local response_msg="🔐 <b>Şifre Gerekli</b><br><br>Bildirimlere abone olmak için şifreyi girin:<br><code>/password ŞİFRE</code>"
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$chat_id" \
                -d text="$response_msg" \
                -d parse_mode="HTML" >/dev/null 2>&1
            continue
        fi
        
        # /password komutu
        if echo "$text" | grep -q "^/password "; then
            local provided_password=$(echo "$text" | sed 's/^\/password //' | tr -d '\n\r ')
            
            if check_password "$provided_password"; then
                if ! grep -q "^${chat_id}$" "$SUBSCRIBERS_FILE" 2>/dev/null; then
                    echo "$chat_id" >> "$SUBSCRIBERS_FILE"
                    log "Yeni abone: $chat_id"
                fi
                
                local success_msg="✅ <b>Başarılı!</b><br><br>CPU bildirimlerine abone oldunuz.<br><b>Sunucu:</b> $(hostname)<br><b>Eşik:</b> ${CPU_THRESHOLD}%"
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -d chat_id="$chat_id" \
                    -d text="$success_msg" \
                    -d parse_mode="HTML" >/dev/null 2>&1
            else
                local error_msg="❌ <b>Hatalı Şifre</b><br><br>Girdiğiniz şifre yanlış. Lütfen tekrar deneyin."
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -d chat_id="$chat_id" \
                    -d text="$error_msg" \
                    -d parse_mode="HTML" >/dev/null 2>&1
            fi
            continue
        fi
        
        # /status komutu
        if [ "$text" = "/status" ]; then
            if grep -q "^${chat_id}$" "$SUBSCRIBERS_FILE" 2>/dev/null; then
                local cpu=$(get_cpu_usage)
                local status_msg="📊 <b>Durum</b><br><br><b>Sunucu:</b> $(hostname)<br><b>CPU:</b> ${cpu}%<br><b>Eşik:</b> ${CPU_THRESHOLD}%<br><b>Durum:</b> ✅ Aktif"
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -d chat_id="$chat_id" \
                    -d text="$status_msg" \
                    -d parse_mode="HTML" >/dev/null 2>&1
            else
                local not_subscribed_msg="⚠️ Bildirimlere abone değilsiniz. <code>/start</code> ile başlayın."
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -d chat_id="$chat_id" \
                    -d text="$not_subscribed_msg" \
                    -d parse_mode="HTML" >/dev/null 2>&1
            fi
            continue
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"
    
    # Offset'i güncelle
    if [ "$max_update_id" -gt 0 ]; then
        echo $((max_update_id + 1)) > "$LAST_OFFSET_FILE"
    fi
}

# Diagnostic raporu oluştur
create_diagnostic_report() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local report_file="$LOG_DIR/diagnostic_${timestamp}.txt"
    
    {
        echo "=========================================="
        echo "CPU SPIKE DIAGNOSTIC REPORT"
        echo "Time: $(date)"
        echo "Hostname: $(hostname)"
        echo "=========================================="
        echo ""
        echo "--- CPU & LOAD AVERAGE ---"
        uptime
        echo ""
        top -bn1 | head -20
        echo ""
        echo "--- TOP 15 CPU CONSUMING PROCESSES ---"
        ps aux --sort=-%cpu | head -16
        echo ""
        echo "--- MEMORY USAGE ---"
        free -h
        echo ""
        echo "--- DISK USAGE ---"
        df -h
        echo ""
        echo "--- NETWORK CONNECTIONS ---"
        netstat -tunap 2>/dev/null | head -30 || ss -tunap 2>/dev/null | head -30
        echo ""
        echo "=========================================="
    } > "$report_file"
    
    echo "$report_file"
}

# Özet mesaj oluştur
create_alert_message() {
    local cpu_usage="$1"
    local report_file="$2"
    
    local hostname=$(hostname)
    local datetime=$(date '+%Y-%m-%d %H:%M:%S')
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ *//')
    local mem_info=$(free -h | grep Mem)
    local mem_used=$(echo $mem_info | awk '{print $3}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    
    local top_processes=$(ps aux --sort=-%cpu | head -4 | tail -3 | awk '{printf "%s %s%%\n", $11, $3}' | sed ':a;N;$!ba;s/\n/<br>/g')
    
    local message="🚨 <b>CPU UYARISI</b><br><br>"
    message+="<b>Sunucu:</b> $hostname<br>"
    message+="<b>Zaman:</b> $datetime<br>"
    message+="<b>CPU Kullanımı:</b> ${cpu_usage}%<br><br>"
    message+="<b>Load Average:</b> $load_avg<br>"
    message+="<b>Bellek:</b> ${mem_used} / ${mem_total}<br><br>"
    message+="<b>En Çok CPU Kullanan 3 Process:</b><br>"
    message+="<code>$top_processes</code>"
    
    echo "$message"
}

# Ana monitoring döngüsü
main() {
    log "CPU Monitor başlatılıyor (Eşik: ${CPU_THRESHOLD}%)"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log "HATA: Telegram bot token ayarlanmamış!"
        exit 1
    fi
    
    # Şifre dosyası yoksa oluştur
    if [ ! -f "$PASSWORD_FILE" ]; then
        echo "1234" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        log "Varsayılan şifre oluşturuldu: 1234 (telegram_password.txt dosyasını düzenleyin)"
    fi
    
    consecutive_high=0
    last_alert_time=0
    update_check_counter=0
    
    while true; do
        # Telegram mesajlarını kontrol et (her 10 döngüde bir)
        update_check_counter=$((update_check_counter + 1))
        if [ $update_check_counter -ge 10 ]; then
            process_telegram_updates
            update_check_counter=0
        fi
        
        # CPU kullanımını kontrol et
        cpu_usage=$(get_cpu_usage)
        cpu_usage_int=${cpu_usage%.*}
        
        if [ "$cpu_usage_int" -ge "$CPU_THRESHOLD" ]; then
            consecutive_high=$((consecutive_high + 1))
            log "Yüksek CPU tespit edildi: ${cpu_usage}% (${consecutive_high}/3)"
            
            # 3 kez üst üste yüksekse uyarı gönder
            if [ $consecutive_high -ge 3 ]; then
                current_time=$(date +%s)
                time_since_alert=$((current_time - last_alert_time))
                
                # Son uyarıdan 5 dakika geçtiyse yeni uyarı gönder
                if [ $time_since_alert -gt 300 ]; then
                    report_file=$(create_diagnostic_report)
                    alert_message=$(create_alert_message "$cpu_usage" "$report_file")
                    send_telegram "$alert_message"
                    send_telegram_file "$report_file" "Detaylı diagnostic raporu"
                    log "Uyarı gönderildi. Rapor: $report_file"
                    last_alert_time=$current_time
                fi
                consecutive_high=0
            fi
        else
            consecutive_high=0
        fi
        
        sleep $CHECK_INTERVAL
    done
}

main
