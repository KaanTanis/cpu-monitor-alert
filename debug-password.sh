#!/bin/bash

# Password komutu debug scripti
# Bu script /password komutunun nasıl işlendiğini test eder

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD_FILE="$SCRIPT_DIR/telegram_password.txt"

echo "=========================================="
echo "Password Komutu Debug Testi"
echo "=========================================="
echo ""

# 1. Şifre dosyasını kontrol et
echo "1. Şifre dosyası kontrolü..."
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "❌ Şifre dosyası yok: $PASSWORD_FILE"
    echo "    Varsayılan şifre oluşturuluyor..."
    echo "1234" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
else
    echo "✓ Şifre dosyası mevcut: $PASSWORD_FILE"
fi

stored_password=$(cat "$PASSWORD_FILE" | tr -d '\n\r ')
echo "   Saklanan şifre: '$stored_password' (uzunluk: ${#stored_password})"
echo ""

# 2. Regex testi
echo "2. Regex testi..."
test_commands=(
    "/password 1234"
    "/password@botname 1234"
    "/password1234"
    "password 1234"
)

for cmd in "${test_commands[@]}"; do
    if echo "$cmd" | grep -qE "^/password(@[^ ]+)? "; then
        echo "✓ MATCH: '$cmd'"
        extracted=$(echo "$cmd" | sed -E 's/^\/password(@[^ ]+)? //' | tr -d '\n\r ')
        echo "   Çıkarılan: '$extracted'"
    else
        echo "✗ NO MATCH: '$cmd'"
    fi
done
echo ""

# 3. Şifre karşılaştırma testi
echo "3. Şifre karşılaştırma testi..."
test_passwords=("1234" "12345" "1234 " " 1234" "")

for test_pwd in "${test_passwords[@]}"; do
    cleaned_test=$(echo "$test_pwd" | tr -d '\n\r ')
    if [ "$cleaned_test" = "$stored_password" ]; then
        echo "✓ MATCH: '$test_pwd' -> '$cleaned_test' (uzunluk: ${#cleaned_test})"
    else
        echo "✗ NO MATCH: '$test_pwd' -> '$cleaned_test' (uzunluk: ${#cleaned_test}) vs stored (uzunluk: ${#stored_password})"
    fi
done
echo ""

# 4. Tam akış testi
echo "4. Tam akış testi..."
test_message="/password 1234"
echo "Test mesajı: '$test_message'"

if echo "$test_message" | grep -qE "^/password(@[^ ]+)? "; then
    echo "✓ Komut algılandı"
    extracted_password=$(echo "$test_message" | sed -E 's/^\/password(@[^ ]+)? //' | tr -d '\n\r ')
    echo "✓ Şifre çıkarıldı: '$extracted_password' (uzunluk: ${#extracted_password})"
    
    if [ "$extracted_password" = "$stored_password" ]; then
        echo "✓ Şifre eşleşti!"
        echo "✓ Abonelik başarılı olmalı"
    else
        echo "✗ Şifre eşleşmedi!"
        echo "   Extracted: '$extracted_password' (uzunluk: ${#extracted_password})"
        echo "   Stored: '$stored_password' (uzunluk: ${#stored_password})"
    fi
else
    echo "✗ Komut algılanmadı!"
fi
echo ""

# 5. Şifre dosyası içeriğini hex olarak göster
echo "5. Şifre dosyası içeriği (hex):"
hexdump -C "$PASSWORD_FILE" | head -5
echo ""

echo "=========================================="
echo "Test tamamlandı!"
echo "=========================================="

