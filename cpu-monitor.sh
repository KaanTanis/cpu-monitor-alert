#!/bin/bash

##############################################
# CPU Monitor - Telegram Bildirimleri
# CPU belirli yüzdeyi aşarsa Telegram botuna bildirim gönderir
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
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log "UYARI: TELEGRAM_BOT_TOKEN boş! Telegram mesajları işlenemiyor."
        return 1
    fi
    
    # jq kontrolü
    if ! command -v jq >/dev/null 2>&1; then
        log "HATA: jq bulunamadı. 'apt-get install jq' veya 'brew install jq' ile yükleyin."
        return 1
    fi
    
    local last_offset=$(cat "$LAST_OFFSET_FILE" 2>/dev/null || echo "0")
    
    # getUpdates çağrısı - daha kısa timeout ve hata kontrolü
    local updates=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$last_offset&timeout=5" 2>&1)
    local curl_exit_code=$?
    
    # Curl hatası kontrolü
    if [ $curl_exit_code -ne 0 ]; then
        log "Curl hatası (exit code: $curl_exit_code): $updates"
        return 1
    fi
    
    # API yanıtını kontrol et
    if [ -z "$updates" ]; then
        log "UYARI: getUpdates boş yanıt döndü"
        return 1
    fi
    
    # JSON geçerliliği kontrolü
    if ! echo "$updates" | jq . >/dev/null 2>&1; then
        log "HATA: getUpdates geçersiz JSON döndü: $updates"
        return 1
    fi
    
    # API hatası kontrolü
    if echo "$updates" | jq -e '.ok == false' >/dev/null 2>&1; then
        local error_code=$(echo "$updates" | jq -r '.error_code // "unknown"' 2>/dev/null)
        local error_desc=$(echo "$updates" | jq -r '.description // "Unknown error"' 2>/dev/null)
        log "Telegram API hatası (code: $error_code): $error_desc"
        return 1
    fi
    
    # OK kontrolü
    if ! echo "$updates" | jq -e '.ok == true' >/dev/null 2>&1; then
        log "HATA: getUpdates beklenmeyen yanıt: $updates"
        return 1
    fi
    
    # Update sayısını kontrol et
    local update_count=$(echo "$updates" | jq '.result | length' 2>/dev/null)
    if [ -z "$update_count" ] || [ "$update_count" = "0" ]; then
        # Update yok, bu normal - sessizce devam et
        return 0
    fi
    
    log "Telegram update alındı: $update_count adet (offset: $last_offset)"
    
    # Debug: İlk update'i logla
    if [ "$update_count" -gt 0 ]; then
        local first_update=$(echo "$updates" | jq '.result[0]' 2>/dev/null)
        log "İlk update detayı: $first_update"
    fi
    
    local max_update_id=$last_offset
    local temp_file=$(mktemp)
    
    # Mesajları parse et - hem message.text hem de edited_message.text'i kontrol et
    echo "$updates" | jq -r '.result[]? | 
        if .message then
            "\(.update_id)|\(.message.chat.id // "")|\(.message.text // "")"
        elif .edited_message then
            "\(.update_id)|\(.edited_message.chat.id // "")|\(.edited_message.text // "")"
        else
            empty
        end' > "$temp_file" 2>&1
    
    # jq parsing hatası kontrolü
    if [ $? -ne 0 ]; then
        local jq_error=$(cat "$temp_file" 2>/dev/null)
        log "HATA: jq parsing hatası: $jq_error"
        rm -f "$temp_file"
        return 1
    fi
    
    if [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        # Update var ama mesaj yok, yine de offset'i güncelle
        local max_id=$(echo "$updates" | jq -r '[.result[].update_id] | max // 0' 2>/dev/null)
        if [ "$max_id" -gt 0 ]; then
            echo $((max_id + 1)) > "$LAST_OFFSET_FILE"
        fi
        return 0
    fi
    
    while IFS='|' read -r update_id chat_id text; do
        [ -z "$update_id" ] && continue
        
        # Max update ID'yi güncelle
        if [ "$update_id" -gt "$max_update_id" ]; then
            max_update_id=$update_id
        fi
        
        # Chat ID veya text yoksa atla
        if [ -z "$chat_id" ] || [ -z "$text" ]; then
            continue
        fi
        
        log "Mesaj işleniyor: update_id=$update_id, chat_id=$chat_id, text=$text"
        
        # /start komutu (bot kullanıcı adı ile veya sadece /start)
        if echo "$text" | grep -q "^/start"; then
            log "Start komutu alındı: chat_id=$chat_id, text=$text"
            local response_msg="🔐 <b>Şifre Gerekli</b>

Bildirimlere abone olmak için şifreyi girin:
<code>/password ŞİFRE</code>"
            local response=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$chat_id" \
                -d text="$response_msg" \
                -d parse_mode="HTML" 2>&1)
            
            if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
                log "✓ Start mesajı başarıyla gönderildi: chat_id=$chat_id"
            else
                local error_code=$(echo "$response" | jq -r '.error_code // "unknown"' 2>/dev/null)
                local error_msg=$(echo "$response" | jq -r '.description // "Unknown error"' 2>/dev/null)
                log "✗ Mesaj gönderilemedi (chat_id: $chat_id, error_code: $error_code, error: $error_msg)"
                if [ -n "$response" ]; then
                    log "Response: $response"
                fi
            fi
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
                log "Hatalı şifre denemesi: $chat_id"
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
    
    # Offset'i güncelle (bir sonraki update için)
    # max_update_id hala last_offset'a eşitse, tüm update'lerin ID'lerini kontrol et
    if [ "$max_update_id" -eq "$last_offset" ] || [ "$max_update_id" -lt "$last_offset" ]; then
        # Tüm update ID'lerini al ve max'ı bul
        local all_update_ids=$(echo "$updates" | jq -r '.result[].update_id' 2>/dev/null)
        if [ -n "$all_update_ids" ]; then
            max_update_id=$(echo "$all_update_ids" | sort -n | tail -1)
        fi
    fi
    
    if [ -n "$max_update_id" ] && [ "$max_update_id" -gt 0 ]; then
        local new_offset=$((max_update_id + 1))
        echo "$new_offset" > "$LAST_OFFSET_FILE"
        if [ "$new_offset" -ne "$((last_offset + 1))" ] && [ "$max_update_id" -ne "$last_offset" ]; then
            log "Offset güncellendi: $last_offset -> $new_offset (max_update_id: $max_update_id)"
        fi
    fi
    
    return 0
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

# Telegram bot bağlantısını test et
test_telegram_connection() {
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log "HATA: TELEGRAM_BOT_TOKEN boş!"
        return 1
    fi
    
    log "Telegram bot bağlantısı test ediliyor..."
    local test_response=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>&1)
    
    if echo "$test_response" | jq -e '.ok == true' >/dev/null 2>&1; then
        local bot_username=$(echo "$test_response" | jq -r '.result.username // "unknown"' 2>/dev/null)
        local bot_name=$(echo "$test_response" | jq -r '.result.first_name // "unknown"' 2>/dev/null)
        log "✓ Telegram bot bağlantısı başarılı: @$bot_username ($bot_name)"
        return 0
    else
        local error_code=$(echo "$test_response" | jq -r '.error_code // "unknown"' 2>/dev/null)
        local error_desc=$(echo "$test_response" | jq -r '.description // "Unknown error"' 2>/dev/null)
        log "✗ Telegram bot bağlantısı başarısız (error_code: $error_code, error: $error_desc)"
        log "Test response: $test_response"
        return 1
    fi
}

# Ana monitoring döngüsü
main() {
    log "CPU Monitor başlatılıyor (Eşik: ${CPU_THRESHOLD}%)"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log "HATA: Telegram bot token ayarlanmamış!"
        log "Lütfen cpu-monitor.sh dosyasında TELEGRAM_BOT_TOKEN değişkenini ayarlayın."
        exit 1
    fi
    
    # Telegram bağlantısını test et
    if ! test_telegram_connection; then
        log "HATA: Telegram bot bağlantısı başarısız. Script durduruluyor."
        exit 1
    fi
    
    # Şifre dosyası yoksa oluştur
    if [ ! -f "$PASSWORD_FILE" ]; then
        echo "1234" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        log "Varsayılan şifre oluşturuldu: 1234 (telegram_password.txt dosyasını düzenleyin)"
    fi
    
    # Offset dosyasını kontrol et
    if [ ! -f "$LAST_OFFSET_FILE" ]; then
        echo "0" > "$LAST_OFFSET_FILE"
        log "Offset dosyası oluşturuldu (başlangıç: 0)"
    else
        local current_offset=$(cat "$LAST_OFFSET_FILE" 2>/dev/null || echo "0")
        log "Mevcut offset: $current_offset"
    fi
    
    consecutive_high=0
    last_alert_time=0
    
    log "Monitoring başlatıldı. Telegram mesajları dinleniyor..."
    
    while true; do
        # Telegram mesajlarını kontrol et (her döngüde - yaklaşık 10 saniyede bir)
        process_telegram_updates
        
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
