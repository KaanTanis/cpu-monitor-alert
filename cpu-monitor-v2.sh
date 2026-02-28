#!/bin/bash

##############################################
# CPU Monitor - Telegram Bildirimleri
# CPU eşik değerini aştığında detaylı rapor gönderir
# Geliştirilmiş versiyon: Bot tespiti, header analizi,
# nginx/apache/php-fpm/mysql detayları
##############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

# Varsayılan değerler
DEFAULT_CPU_THRESHOLD=90
DEFAULT_CHECK_INTERVAL=10
DEFAULT_CONSECUTIVE_CHECKS=3
DEFAULT_ALERT_INTERVAL=300
DEFAULT_LOG_RETENTION_DAYS=7
DEFAULT_SECRET_KEY="your_secret_key_here"
DEFAULT_TELEGRAM_BOT_TOKEN=""

# ─── Config yönetimi ─────────────────────────────────────────────────────────

create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# CPU Monitor Konfigürasyonu

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

# Uyarılar arası minimum süre (saniye)
ALERT_INTERVAL=$DEFAULT_ALERT_INTERVAL

# Log dosyalarını kaç gün saklasın
LOG_RETENTION_DAYS=$DEFAULT_LOG_RETENTION_DAYS

# Nginx access log paterni (birden fazla yol space ile ayrılır)
# Örnek: "/var/log/nginx/access.log /var/log/nginx/site-access.log"
NGINX_LOG_PATTERN="/var/log/nginx/*access*.log"

# Apache access log paterni
APACHE_LOG_PATTERN="/var/log/apache2/*access*.log /var/log/httpd/*access*.log"

# Şüpheli IP için istek eşiği
SUSPICIOUS_IP_THRESHOLD=500

# Bot pattern'ı eşleşen IP'leri otomatik logla (0=hayır, 1=evet)
AUTO_LOG_BOT_IPS=1
EOF
    echo "Varsayılan config dosyası oluşturuldu: $CONFIG_FILE"
    echo "Lütfen TELEGRAM_BOT_TOKEN ve SECRET_KEY değerlerini düzenleyin!"
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        create_default_config
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ "$TELEGRAM_BOT_TOKEN" = "$DEFAULT_TELEGRAM_BOT_TOKEN" ]; then
        echo "HATA: TELEGRAM_BOT_TOKEN ayarlanmamış! $CONFIG_FILE dosyasını düzenleyin."
        exit 1
    fi
    if [ -z "$SECRET_KEY" ] || [ "$SECRET_KEY" = "$DEFAULT_SECRET_KEY" ]; then
        echo "HATA: SECRET_KEY varsayılan değerde! $CONFIG_FILE dosyasında değiştirin."
        exit 1
    fi

    CPU_THRESHOLD=${CPU_THRESHOLD:-$DEFAULT_CPU_THRESHOLD}
    CHECK_INTERVAL=${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}
    CONSECUTIVE_CHECKS=${CONSECUTIVE_CHECKS:-$DEFAULT_CONSECUTIVE_CHECKS}
    ALERT_INTERVAL=${ALERT_INTERVAL:-$DEFAULT_ALERT_INTERVAL}
    LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-$DEFAULT_LOG_RETENTION_DAYS}
    NGINX_LOG_PATTERN=${NGINX_LOG_PATTERN:-"/var/log/nginx/*access*.log"}
    APACHE_LOG_PATTERN=${APACHE_LOG_PATTERN:-"/var/log/apache2/*access*.log /var/log/httpd/*access*.log"}
    SUSPICIOUS_IP_THRESHOLD=${SUSPICIOUS_IP_THRESHOLD:-500}
    AUTO_LOG_BOT_IPS=${AUTO_LOG_BOT_IPS:-1}
}

load_config

# ─── Dizinler ─────────────────────────────────────────────────────────────────

[ "$(uname)" = "Darwin" ] && LOG_DIR="$SCRIPT_DIR/logs" || LOG_DIR="/var/log/cpu-monitor"
SUBSCRIBERS_FILE="$LOG_DIR/subscribers.txt"
LAST_OFFSET_FILE="$LOG_DIR/last_offset.txt"
BOT_IPS_FILE="$LOG_DIR/detected_bot_ips.txt"

mkdir -p "$LOG_DIR"
touch "$SUBSCRIBERS_FILE" "$LAST_OFFSET_FILE" "$BOT_IPS_FILE" 2>/dev/null

# ─── Yardımcı fonksiyonlar ────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/monitor.log" 2>/dev/null
}

cleanup_old_logs() {
    find "$LOG_DIR" -name "cpu_report_*.txt" -type f -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
    if [ -f "$LOG_DIR/monitor.log" ]; then
        tail -n 10000 "$LOG_DIR/monitor.log" > "$LOG_DIR/monitor.log.tmp" 2>/dev/null
        mv "$LOG_DIR/monitor.log.tmp" "$LOG_DIR/monitor.log" 2>/dev/null
    fi
}

# ─── CPU kullanımı ────────────────────────────────────────────────────────────

get_cpu_usage() {
    local usage=""
    if [ "$(uname)" = "Darwin" ]; then
        usage=$(top -l 1 | grep "CPU usage" | awk '{print $3}' | sed 's/%//')
    else
        # /proc/stat üzerinden daha güvenilir ölçüm
        local line1 line2
        line1=$(grep '^cpu ' /proc/stat)
        sleep 1
        line2=$(grep '^cpu ' /proc/stat)

        local idle1 total1 idle2 total2
        idle1=$(echo "$line1" | awk '{print $5}')
        total1=$(echo "$line1" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
        idle2=$(echo "$line2" | awk '{print $5}')
        total2=$(echo "$line2" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')

        local diff_idle=$(( idle2 - idle1 ))
        local diff_total=$(( total2 - total1 ))
        if [ "$diff_total" -gt 0 ]; then
            usage=$(awk "BEGIN {printf \"%.1f\", (1 - $diff_idle/$diff_total) * 100}")
        else
            usage="0.0"
        fi
    fi
    echo "${usage:-0}"
}

# ─── Log dosyalarını topla ────────────────────────────────────────────────────

collect_web_logs() {
    # Nginx ve Apache loglarını birleştirerek geçici dosyaya yaz
    local tmpfile
    tmpfile=$(mktemp)
    # shellcheck disable=SC2086
    cat $NGINX_LOG_PATTERN $APACHE_LOG_PATTERN 2>/dev/null > "$tmpfile"
    echo "$tmpfile"
}

# ─── Bot pattern tespiti ──────────────────────────────────────────────────────

# Bilinen bot/scraper/scanner user-agent pattern'ları
BOT_UA_PATTERNS=(
    # Tarayıcı olmayan crawler'lar
    "python-requests" "python-urllib" "python-httpx" "aiohttp" "httpie"
    "go-http-client" "java/" "okhttp" "libwww-perl" "lwp-request"
    "curl/" "wget/" "scrapy" "mechanize"
    # Scanner'lar
    "nikto" "sqlmap" "nmap" "masscan" "zgrab" "nuclei"
    "dirbuster" "gobuster" "ffuf" "wfuzz" "hydra"
    "acunetix" "nessus" "openvas" "burpsuite" "zaproxy"
    # Kötü niyetli botlar / credential stuffing
    "semrush" "ahrefsbot" "mj12bot" "dotbot" "blexbot"
    "petalbot" "yandexbot" "baiduspider" "megaindex"
    # DDoS aracı imzaları
    "loic" "hoic" "slowloris" "hulk" "pyloris"
    # Boş / çok kısa UA (genellikle bot)
    "^-$" "^$" "test" "exploit" "attack"
)

# Şüpheli URI pattern'ları (saldırı/tarama belirtisi)
SUSPICIOUS_URI_PATTERNS=(
    # Web shell / backdoor denemeleri
    "\.php\?.*cmd=" "\.php\?.*exec=" "\.php\?.*system="
    "c99\.php" "r57\.php" "shell\.php" "b374k" "wso\.php"
    "wp-config\.php" "wp-login\.php" "/xmlrpc\.php"
    # Path traversal
    "\.\./\.\." "etc/passwd" "etc/shadow" "proc/self"
    # SQL injection belirtisi
    "union.*select" "select.*from" "or.*1=1" "' or '" "\" or \""
    "information_schema" "sleep(" "benchmark("
    # LFI/RFI
    "php://input" "php://filter" "data://text" "expect://"
    # Scanner imzaları
    "\.env" "\.git/" "\.svn/" "\.htaccess" "\.DS_Store"
    "/admin/" "/phpmyadmin" "/pma/" "/myadmin"
    "/.well-known/security" "/actuator/" "/api/swagger"
    # Brute force / credential stuffing
    "/wp-login" "/administrator/index" "/joomla" "/drupal"
)

detect_bot_patterns() {
    local logfile="$1"
    local output=""

    output+="=== BOT & SALDIRI TESPİTİ ===\n\n"

    # ── 1. User-Agent bazlı bot tespiti ──────────────────────────────────────
    output+="--- Şüpheli User-Agent'lar (bot/scanner/scraper) ---\n"
    local ua_result=""
    for pattern in "${BOT_UA_PATTERNS[@]}"; do
        local matches
        matches=$(grep -i "$pattern" "$logfile" 2>/dev/null | \
                  awk '{print $1}' | sort | uniq -c | sort -nr | head -5)
        if [ -n "$matches" ]; then
            ua_result+="[Pattern: $pattern]\n$matches\n"
        fi
    done
    [ -n "$ua_result" ] && output+="$ua_result" || output+="Tespit edilmedi.\n"
    output+="\n"

    # ── 2. Şüpheli URI tespiti ────────────────────────────────────────────────
    output+="--- Şüpheli URI İstekleri (saldırı/tarama belirtisi) ---\n"
    local uri_result=""
    for pattern in "${SUSPICIOUS_URI_PATTERNS[@]}"; do
        local matches
        matches=$(grep -iE "$pattern" "$logfile" 2>/dev/null | \
                  awk '{print $1, $7}' | sort | uniq -c | sort -nr | head -5)
        if [ -n "$matches" ]; then
            uri_result+="[Pattern: $pattern]\n$matches\n"
        fi
    done
    [ -n "$uri_result" ] && output+="$uri_result" || output+="Tespit edilmedi.\n"
    output+="\n"

    # ── 3. HTTP metodlarına göre analiz ──────────────────────────────────────
    output+="--- HTTP Metod Dağılımı ---\n"
    output+="$(awk '{print $6}' "$logfile" 2>/dev/null | tr -d '"' | sort | uniq -c | sort -nr | head -10)\n\n"

    # ── 4. Yüksek hata oranı olan IP'ler (4xx/5xx) ───────────────────────────
    output+="--- Yüksek 4xx/5xx Oranı olan IP'ler (bot/scanner belirtisi) ---\n"
    output+="$(awk '$9 ~ /^[45]/ {print $1}' "$logfile" 2>/dev/null | \
               sort | uniq -c | sort -nr | head -20)\n\n"

    # ── 5. Hız anomalisi: Saniyede çok fazla istek gönderen IP'ler ────────────
    output+="--- Saniyede 10+ İstek Gönderen IP'ler (flood/DDoS belirtisi) ---\n"
    local flood_ips
    flood_ips=$(awk '{print $1, $4}' "$logfile" 2>/dev/null | \
                sed 's/\[//' | sed 's/:/ /' | \
                awk '{print $1, $2, $3}' | \
                sort | uniq -c | \
                awk '$1 >= 10 {print $2, "tarih:", $3, "saniyede:", $1}' | \
                sort -rn | head -20)
    [ -n "$flood_ips" ] && output+="$flood_ips\n" || output+="Tespit edilmedi.\n"
    output+="\n"

    # ── 6. Boş veya anormal User-Agent ile gelen istekler ────────────────────
    output+="--- Boş/Anormal User-Agent ile İstekler ---\n"
    output+="$(awk -F'"' '$6 == "-" || $6 == "" || length($6) < 10 {print $1}' "$logfile" 2>/dev/null | \
               awk '{print $1}' | sort | uniq -c | sort -nr | head -20)\n\n"

    # ── 7. Referrer analizi (spam/bot referrer) ───────────────────────────────
    output+="--- Şüpheli Referrer'lar ---\n"
    output+="$(awk -F'"' '{print $4}' "$logfile" 2>/dev/null | \
               grep -v "^-$" | grep -v "^$" | \
               sort | uniq -c | sort -nr | head -20)\n\n"

    # ── 8. POST flood (form spam / brute force) ───────────────────────────────
    output+="--- En Fazla POST İsteği Gönderen IP'ler ---\n"
    output+="$(grep '"POST ' "$logfile" 2>/dev/null | \
               awk '{print $1}' | sort | uniq -c | sort -nr | head -20)\n\n"

    # ── 9. Aynı IP'den farklı UA kullanımı (bot rotation) ────────────────────
    output+="--- Birden Fazla User-Agent Kullanan IP'ler (bot rotation) ---\n"
    output+="$(awk -F'"' '{print $1, $6}' "$logfile" 2>/dev/null | \
               awk '{print $1}' | sort | uniq -c | sort -nr | \
               awk 'NR==FNR{c[$2]+=$1; next} c[$1]>3{print c[$1], $1}' | \
               sort -rn | head -20)\n\n"

    printf "%b" "$output"
}

# ─── Detaylı sistem raporu ────────────────────────────────────────────────────

create_report() {
    local cpu_usage="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local report_file="$LOG_DIR/cpu_report_${timestamp}.txt"

    {
        echo "=========================================="
        echo "CPU SPIKE REPORT"
        echo "Zaman   : $(date)"
        echo "Hostname: $(hostname)"
        echo "CPU     : ${cpu_usage}%  (Eşik: ${CPU_THRESHOLD}%)"
        echo "=========================================="
        echo ""

        # ── Genel Sistem ──────────────────────────────────────────────────────
        echo "--- UPTIME & LOAD AVERAGE ---"
        uptime
        echo ""

        echo "--- CPU DETAYI (mpstat) ---"
        if command -v mpstat >/dev/null 2>&1; then
            mpstat -P ALL 1 1
        else
            if [ "$(uname)" = "Darwin" ]; then
                top -l 1 | head -15
            else
                top -bn1 | head -20
            fi
        fi
        echo ""

        echo "--- TOP 25 CPU TÜKETİCİSİ ---"
        ps aux --sort=-%cpu 2>/dev/null | head -26 || ps aux -r | head -26
        echo ""

        echo "--- TOP 25 BELLEK TÜKETİCİSİ ---"
        ps aux --sort=-%mem 2>/dev/null | head -26 || ps aux -m | head -26
        echo ""

        echo "--- BELLEK KULLANIMI ---"
        if [ "$(uname)" = "Darwin" ]; then
            vm_stat
            sysctl hw.memsize
        else
            free -h
            echo ""
            cat /proc/meminfo 2>/dev/null | head -25
        fi
        echo ""

        echo "--- DISK KULLANIMI ---"
        df -h
        echo ""

        echo "--- DISK I/O (iostat) ---"
        if command -v iostat >/dev/null 2>&1; then
            iostat -xz 1 2 2>/dev/null | tail -n +$(iostat -xz 1 2 2>/dev/null | grep -n "Device" | tail -1 | cut -d: -f1)
        else
            echo "iostat mevcut değil (sysstat paketi kurulu mu?)"
        fi
        echo ""

        echo "--- AĞ BAĞLANTILARI (SYN/TIME_WAIT/ESTABLISHED sayıları) ---"
        if command -v ss >/dev/null 2>&1; then
            echo "State counts:"
            ss -s
            echo ""
            echo "Top 20 bağlantı kaynağı:"
            ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -20
        else
            netstat -s 2>/dev/null | grep -E "connections|segments|packets" | head -20
            echo ""
            netstat -tn 2>/dev/null | awk 'NR>2 {print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -20
        fi
        echo ""

        echo "--- AĞ ARAYÜZ İSTATİSTİKLERİ ---"
        if command -v ip >/dev/null 2>&1; then
            ip -s link
        else
            ifconfig 2>/dev/null | grep -A5 "bytes\|RX\|TX" | head -50
        fi
        echo ""

        # ── PHP-FPM ──────────────────────────────────────────────────────────
        echo "--- PHP-FPM DURUM ---"
        local fpm_count
        fpm_count=$(ps aux | grep php-fpm | grep -v grep | wc -l)
        echo "Toplam php-fpm process: $fpm_count"
        echo ""
        echo "PHP-FPM process detayı:"
        ps aux | grep php-fpm | grep -v grep
        echo ""
        # php-fpm status endpoint varsa
        if command -v curl >/dev/null 2>&1; then
            local fpm_status
            fpm_status=$(curl -s --max-time 2 "http://127.0.0.1/fpm-status?full" 2>/dev/null)
            if [ -n "$fpm_status" ]; then
                echo "PHP-FPM Status (HTTP):"
                echo "$fpm_status" | head -50
            fi
        fi
        echo ""

        # ── MySQL / MariaDB ───────────────────────────────────────────────────
        echo "--- VERİTABANI DURUMU ---"
        if command -v mysqladmin >/dev/null 2>&1; then
            echo "MySQL processlist:"
            mysqladmin processlist 2>/dev/null | head -30 || echo "MySQL bağlantısı başarısız (credentials gerekebilir)"
            echo ""
            echo "MySQL status:"
            mysqladmin status 2>/dev/null || echo "MySQL status alınamadı"
        else
            echo "mysqladmin bulunamadı"
        fi
        echo ""
        # Slow query log son satırları
        for slow_log in /var/log/mysql/mysql-slow.log /var/lib/mysql/*-slow.log; do
            if [ -f "$slow_log" ]; then
                echo "MySQL Slow Query Log (son 20 satır): $slow_log"
                tail -20 "$slow_log"
            fi
        done
        echo ""

        # ── Redis ─────────────────────────────────────────────────────────────
        echo "--- REDIS DURUMU ---"
        if command -v redis-cli >/dev/null 2>&1; then
            redis-cli info server 2>/dev/null | grep -E "redis_version|uptime|connected_clients|mem_allocator" | head -10
            redis-cli info clients 2>/dev/null | head -10
            redis-cli info stats 2>/dev/null | grep -E "total_commands|total_connections|rejected|evicted" | head -10
        else
            echo "redis-cli bulunamadı"
        fi
        echo ""

        # ── Nginx ─────────────────────────────────────────────────────────────
        echo "--- NGINX PROCESS & WORKER SAYISI ---"
        ps aux | grep nginx | grep -v grep
        echo ""

        # Nginx stub_status varsa
        if command -v curl >/dev/null 2>&1; then
            local nginx_status
            nginx_status=$(curl -s --max-time 2 "http://127.0.0.1/nginx_status" 2>/dev/null)
            if [ -n "$nginx_status" ]; then
                echo "Nginx Stub Status:"
                echo "$nginx_status"
            fi
        fi
        echo ""

        # ── Web Log Analizi ───────────────────────────────────────────────────
        local logfile
        logfile=$(collect_web_logs)

        if [ -s "$logfile" ]; then
            echo "--- NGINX/APACHE LOG ANALİZİ ---"
            local total_lines
            total_lines=$(wc -l < "$logfile")
            echo "Toplam log satırı: $total_lines"
            echo ""

            echo "--- TOP 30 İSTEK YAPAN IP ---"
            awk '{print $1}' "$logfile" | sort | uniq -c | sort -nr | head -30
            echo ""

            echo "--- TOP 30 İSTEK YAPILAN URL ---"
            awk '{print $7}' "$logfile" | sort | uniq -c | sort -nr | head -30
            echo ""

            echo "--- HTTP DURUM KODU DAĞILIMI ---"
            awk '{print $9}' "$logfile" | sort | uniq -c | sort -nr
            echo ""

            echo "--- TOP 20 USER AGENT ---"
            awk -F'"' '{print $6}' "$logfile" | sort | uniq -c | sort -nr | head -20
            echo ""

            echo "--- SON 1 SAATTEKİ İSTEK DAĞILIMI (dakika bazlı) ---"
            local one_hour_ago
            one_hour_ago=$(date -d '1 hour ago' '+%d/%b/%Y:%H' 2>/dev/null || date -v-1H '+%d/%b/%Y:%H' 2>/dev/null)
            if [ -n "$one_hour_ago" ]; then
                grep "$one_hour_ago" "$logfile" 2>/dev/null | \
                    awk '{print $4}' | cut -c14-18 | sort | uniq -c
            fi
            echo ""

            echo "--- 404 SAYISI (tüm log) ---"
            grep -c " 404 " "$logfile" 2>/dev/null || echo "0"
            echo ""

            echo "--- EN ÇOK 404 ALAN PATH'ler ---"
            awk '$9 == "404" {print $7}' "$logfile" | sort | uniq -c | sort -nr | head -20
            echo ""

            echo "--- ŞÜPHELİ IP'ler (>${SUSPICIOUS_IP_THRESHOLD} istek) ---"
            awk '{print $1}' "$logfile" | sort | uniq -c | \
                awk -v t="$SUSPICIOUS_IP_THRESHOLD" '$1 > t' | sort -nr
            echo ""

            # ── Bot tespiti ───────────────────────────────────────────────────
            detect_bot_patterns "$logfile"

            # Bot IP'lerini kaydet
            if [ "$AUTO_LOG_BOT_IPS" = "1" ]; then
                echo "--- TESPİT EDİLEN BOT IP KAYDI: $BOT_IPS_FILE ---"
                local bot_ips
                bot_ips=$(awk '{print $1}' "$logfile" | sort | uniq -c | \
                         awk -v t="$SUSPICIOUS_IP_THRESHOLD" '$1 > t {print $2}')
                for ip in $bot_ips; do
                    if ! grep -q "^$ip$" "$BOT_IPS_FILE" 2>/dev/null; then
                        echo "$ip" >> "$BOT_IPS_FILE"
                        echo "Yeni bot IP kaydedildi: $ip"
                    fi
                done
            fi
        else
            echo "--- WEB LOG: Log dosyaları bulunamadı veya boş ---"
            echo "Config'deki NGINX_LOG_PATTERN ve APACHE_LOG_PATTERN değerlerini kontrol edin."
        fi

        [ -f "$logfile" ] && rm -f "$logfile"
        echo ""

        # ── Sistem logları ────────────────────────────────────────────────────
        echo "--- SİSTEM LOGLARI (son 30 satır) ---"
        if [ -f /var/log/syslog ]; then
            tail -30 /var/log/syslog
        elif [ -f /var/log/messages ]; then
            tail -30 /var/log/messages
        elif command -v journalctl >/dev/null 2>&1; then
            journalctl -n 30 --no-pager
        else
            echo "Sistem logu bulunamadı"
        fi
        echo ""

        echo "--- KERNEL HATALARI (dmesg, son 20) ---"
        dmesg 2>/dev/null | grep -iE "error|oom|kill|segfault|out of memory" | tail -20 || echo "dmesg erişimi yok"
        echo ""

        echo "--- OOM KILLER GEÇMİŞİ ---"
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -k --no-pager 2>/dev/null | grep -i "oom\|killed process" | tail -10
        else
            grep -i "oom\|killed process" /var/log/kern.log 2>/dev/null | tail -10 || echo "OOM kaydı bulunamadı"
        fi
        echo ""

        echo "--- ÇALIŞAN SERVİSLER ---"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl list-units --type=service --state=running --no-pager 2>/dev/null | head -40
        else
            service --status-all 2>/dev/null | grep "+" | head -30
        fi
        echo ""

        echo "--- AÇIK DOSYA SAYISI (lsof) ---"
        if command -v lsof >/dev/null 2>&1; then
            echo "Toplam: $(lsof 2>/dev/null | wc -l)"
            echo "Process başına en fazla açık dosya:"
            lsof 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | head -10
        else
            echo "lsof bulunamadı"
        fi
        echo ""

        echo "--- SİSTEM LİMİTLERİ ---"
        ulimit -a 2>/dev/null
        echo ""
        cat /proc/sys/fs/file-nr 2>/dev/null && echo "(dosya tanımlayıcı: kullanılan / serbest / max)"
        echo ""

        echo "=========================================="
        echo "Rapor sonu: $(date)"
        echo "=========================================="

    } > "$report_file" 2>&1

    echo "$report_file"
}

# ─── Telegram fonksiyonları ───────────────────────────────────────────────────

send_telegram() {
    local message="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ ! -s "$SUBSCRIBERS_FILE" ] && return 1

    while IFS= read -r chat_id; do
        [ -z "$chat_id" ] && continue
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$chat_id" \
            --data-urlencode text="$message" \
            -d parse_mode="HTML" >/dev/null 2>&1
    done < "$SUBSCRIBERS_FILE"
}

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

# ─── Telegram update işleme ───────────────────────────────────────────────────

process_telegram_updates() {
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 1

    if ! command -v jq >/dev/null 2>&1; then
        # jq yoksa python ile dene
        if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
            return 1
        fi
    fi

    local last_offset
    last_offset=$(cat "$LAST_OFFSET_FILE" 2>/dev/null)
    last_offset=${last_offset:-0}

    local updates
    updates=$(curl -s --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${last_offset}&timeout=5" 2>/dev/null)

    [ -z "$updates" ] && return 1

    local max_update_id=0

    if command -v jq >/dev/null 2>&1; then
        echo "$updates" | jq -e '.ok == true' >/dev/null 2>&1 || return 1
        local update_count
        update_count=$(echo "$updates" | jq '.result | length' 2>/dev/null)
        [ "${update_count:-0}" = "0" ] && return 0

        max_update_id=$(echo "$updates" | jq -r '[.result[].update_id] | max // 0' 2>/dev/null)

        local temp_file
        temp_file=$(mktemp)
        echo "$updates" | jq -r '.result[]? |
            if .message then
                "\(.update_id)|\(.message.chat.id // "")|\(.message.text // "")"
            elif .edited_message then
                "\(.update_id)|\(.edited_message.chat.id // "")|\(.edited_message.text // "")"
            else empty end' > "$temp_file" 2>/dev/null
    else
        # python fallback
        local py_cmd="import sys,json; data=json.load(sys.stdin); [print('{}|{}|{}'.format(u.get('update_id',''), (u.get('message') or u.get('edited_message',{})).get('chat',{}).get('id',''), (u.get('message') or u.get('edited_message',{})).get('text',''))) for u in data.get('result',[])]"
        local temp_file
        temp_file=$(mktemp)
        echo "$updates" | python3 -c "$py_cmd" > "$temp_file" 2>/dev/null || \
        echo "$updates" | python  -c "$py_cmd" > "$temp_file" 2>/dev/null
        max_update_id=$(echo "$updates" | python3 -c "import sys,json; d=json.load(sys.stdin); ids=[u['update_id'] for u in d.get('result',[])]; print(max(ids) if ids else 0)" 2>/dev/null || echo 0)
    fi

    if [ -s "${temp_file:-}" ]; then
        while IFS='|' read -r update_id chat_id text; do
            [ -z "$update_id" ] || [ -z "$chat_id" ] || [ -z "$text" ] && continue

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

ℹ️ CPU ${CONSECUTIVE_CHECKS} kez üst üste ${CPU_THRESHOLD}% üzerine çıktığında bildirim alacaksınız."
                    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                        -d chat_id="$chat_id" \
                        --data-urlencode text="$response" \
                        -d parse_mode="HTML" >/dev/null 2>&1
                else
                    log "Zaten abone: $chat_id"
                fi
            fi
        done < "$temp_file"
    fi

    [ -n "${temp_file:-}" ] && rm -f "$temp_file"

    if [ -n "$max_update_id" ] && [ "$max_update_id" != "0" ]; then
        echo $(( max_update_id + 1 )) > "$LAST_OFFSET_FILE"
    fi
}

# ─── Ana döngü ────────────────────────────────────────────────────────────────

main() {
    log "CPU Monitor başlatıldı"
    log "Eşik: ${CPU_THRESHOLD}% | Kontrol: ${CONSECUTIVE_CHECKS}x | Aralık: ${CHECK_INTERVAL}s | Bildirim: ${ALERT_INTERVAL}s | Log Saklama: ${LOG_RETENTION_DAYS}gün"

    local consecutive_high=0
    local last_alert_time=0
    local last_cleanup_day
    last_cleanup_day=$(date +%d)

    while true; do
        process_telegram_updates

        local current_day
        current_day=$(date +%d)
        if [ "$current_day" != "$last_cleanup_day" ]; then
            cleanup_old_logs
            last_cleanup_day=$current_day
            log "Eski loglar temizlendi (>${LOG_RETENTION_DAYS} gün)"
        fi

        local cpu_usage
        cpu_usage=$(get_cpu_usage)

        # Sayısal karşılaştırma için tam sayıya çevir (virgüllü değerlere karşı güvenli)
        local cpu_usage_int
        cpu_usage_int=$(printf "%.0f" "${cpu_usage:-0}" 2>/dev/null || echo "0")

        if [ "$cpu_usage_int" -ge "$CPU_THRESHOLD" ] 2>/dev/null; then
            consecutive_high=$(( consecutive_high + 1 ))
            log "CPU yüksek: ${cpu_usage}% (${consecutive_high}/${CONSECUTIVE_CHECKS})"

            if [ "$consecutive_high" -ge "$CONSECUTIVE_CHECKS" ]; then
                local current_time
                current_time=$(date +%s)
                local time_since_alert=$(( current_time - last_alert_time ))

                if [ "$last_alert_time" -eq 0 ] || [ "$time_since_alert" -ge "$ALERT_INTERVAL" ]; then
                    log "Rapor oluşturuluyor..."
                    local report_file
                    report_file=$(create_report "$cpu_usage")

                    local alert_msg="🚨 <b>CPU Uyarısı!</b>

📊 CPU: <b>${cpu_usage}%</b>  (Eşik: ${CPU_THRESHOLD}%)
🔄 Üst üste yüksek: ${consecutive_high}x
⏰ Zaman: $(date '+%H:%M:%S')
🖥 Host: $(hostname)

📁 Detaylı rapor (nginx log analizi, bot tespiti, process listesi) dosya olarak eklendi."

                    send_telegram "$alert_msg"
                    send_telegram_file "$report_file" "📄 CPU Raporu - $(date '+%Y-%m-%d %H:%M:%S')"
                    log "Uyarı gönderildi: CPU ${cpu_usage}% — $(basename "$report_file")"
                    last_alert_time=$current_time
                fi
            fi
        else
            if [ "$consecutive_high" -gt 0 ]; then
                log "CPU normale döndü: ${cpu_usage}% (önceki: ${consecutive_high}x yüksek)"
                consecutive_high=0
                last_alert_time=0  # Yeni spike olursa hemen bildirim gitsin
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main
