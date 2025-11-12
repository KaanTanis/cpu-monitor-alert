#!/bin/bash

##############################################
# CPU Monitor - Telegram Bildirimleri
# CPU eşik değerini aştığında detaylı rapor gönderir
##############################################

# Konfigürasyon
CPU_THRESHOLD=95
CHECK_INTERVAL=10
SECRET_KEY="your_secret_key_here"  # Bu anahtarı değiştirin
TELEGRAM_BOT_TOKEN=""

# Dizinler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    # Boş değer kontrolü ekle
    [ -z "$last_offset" ] && last_offset="0"
    
    local updates=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$last_offset&timeout=5" 2>&1)
    
    [ -z "$updates" ] || ! echo "$updates" | jq -e '.ok == true' >/dev/null 2>&1 && return 1
    
    local update_count=$(echo "$updates" | jq '.result | length' 2>/dev/null)
    [ -z "$update_count" ] || [ "$update_count" = "0" ] && return 0
    
    local max_update_id=$last_offset
    local temp_file=$(mktemp)
    
    echo "$updates" | jq -r '.result[]? | 
        if .message then
            "\(.update_id)|\(.message.chat.id // "")|\(.message.text // "")"
        elif .edited_message then
            "\(.update_id)|\(.edited_message.chat.id // "")|\(.edited_message.text // "")"
        else empty end' > "$temp_file" 2>/dev/null
    
    [ ! -s "$temp_file" ] && {
        local max_id=$(echo "$updates" | jq -r '[.result[].update_id] | max // 0' 2>/dev/null)
        [ -n "$max_id" ] && [ "$max_id" -gt 0 ] && echo $((max_id + 1)) > "$LAST_OFFSET_FILE"
        rm -f "$temp_file"
        return 0
    }
    
    while IFS='|' read -r update_id chat_id text; do
        [ -z "$update_id" ] || [ -z "$chat_id" ] || [ -z "$text" ] && continue
        
        # Integer kontrolü ekle
        if [ -n "$update_id" ] && [ -n "$max_update_id" ]; then
            [ "$update_id" -gt "$max_update_id" ] 2>/dev/null && max_update_id=$update_id
        fi
        
        # Secret key ile abonelik: /start SECRET_KEY veya /SECRET_KEY
        if [ "$text" = "/${SECRET_KEY}" ] || [ "$text" = "/start ${SECRET_KEY}" ]; then
            if ! grep -q "^${chat_id}$" "$SUBSCRIBERS_FILE" 2>/dev/null; then
                echo "$chat_id" >> "$SUBSCRIBERS_FILE"
                log "Yeni abone: $chat_id"
            fi
            
            local response="✅ Abone oldunuz. CPU eşik değeri: ${CPU_THRESHOLD}%"
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$chat_id" \
                -d text="$response" >/dev/null 2>&1
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"
    
    # Integer kontrolü ekle
    if [ -n "$max_update_id" ] && [ -n "$last_offset" ]; then
        [ "$max_update_id" -gt "$last_offset" ] 2>/dev/null && echo $((max_update_id + 1)) > "$LAST_OFFSET_FILE"
    fi
    return 0
}

# Ana monitoring döngüsü
main() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && {
        log "HATA: TELEGRAM_BOT_TOKEN ayarlanmamış"
        exit 1
    }
    
    log "CPU Monitor başlatıldı (Eşik: ${CPU_THRESHOLD}%)"
    
    local consecutive_high=0
    local last_alert_time=0
    
    while true; do
        process_telegram_updates
        
        local cpu_usage=$(get_cpu_usage)
        local cpu_usage_int=${cpu_usage%.*}
        
        if [ "$cpu_usage_int" -ge "$CPU_THRESHOLD" ]; then
            consecutive_high=$((consecutive_high + 1))
            
            if [ $consecutive_high -ge 3 ]; then
                local current_time=$(date +%s)
                local time_since_alert=$((current_time - last_alert_time))
                
                if [ $time_since_alert -gt 300 ]; then
                    local report_file=$(create_report "$cpu_usage")
                    local alert_msg="🚨 CPU Uyarısı: ${cpu_usage}% (Eşik: ${CPU_THRESHOLD}%)"
                    
                    send_telegram "$alert_msg"
                    send_telegram_file "$report_file" "Detaylı CPU Raporu"
                    
                    log "Uyarı gönderildi: CPU ${cpu_usage}% (Rapor: $report_file)"
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