#!/bin/sh
# xray-geoupdate.sh — обновление geodata (geoip.dat + geosite.dat) от Loyalsoldier.
#
# Использование:
#   xray-geoupdate         скачать свежие geoip.dat и geosite.dat, заменить, перезапустить
#   xray-geoupdate show     показать даты текущих файлов geodata
#
# geodata независима от версии ядра Xray. Обновлять желательно раз в несколько месяцев,
# т.к. со временем меняются диапазоны IP и списки доменов (влияет на точность smart-ru).

SHARE="/opt/xray/share"
GEOIP="$SHARE/geoip.dat"
GEOSITE="$SHARE/geosite.dat"
SERVICE="/etc/init.d/xray-tproxy"
BACKUP_DIR="/opt/xray/backup"

GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# --- SHOW ---
if [ "$1" = "show" ]; then
    echo "=== Текущая geodata ==="
    ls -la "$GEOIP" "$GEOSITE" 2>/dev/null
    exit 0
fi

echo "=== Обновление geodata (Loyalsoldier) ==="

# скачиваем во временные файлы
echo "Скачивание geoip.dat..."
if ! curl -fsSL --max-time 120 -o /tmp/geoip.dat.new "$GEOIP_URL"; then
    echo "Ошибка: не удалось скачать geoip.dat. Изменений не внесено."
    rm -f /tmp/geoip.dat.new
    exit 1
fi
echo "Скачивание geosite.dat..."
if ! curl -fsSL --max-time 120 -o /tmp/geosite.dat.new "$GEOSITE_URL"; then
    echo "Ошибка: не удалось скачать geosite.dat. Изменений не внесено."
    rm -f /tmp/geoip.dat.new /tmp/geosite.dat.new
    exit 1
fi

# проверка, что файлы не пустые и разумного размера (geodata обычно > 1 МБ)
SIZE_IP=$(wc -c < /tmp/geoip.dat.new)
SIZE_SITE=$(wc -c < /tmp/geosite.dat.new)
if [ "$SIZE_IP" -lt 100000 ] || [ "$SIZE_SITE" -lt 100000 ]; then
    echo "Ошибка: скачанные файлы подозрительно малы (geoip=$SIZE_IP, geosite=$SIZE_SITE байт)."
    echo "Возможно, скачалась ошибка вместо данных. Изменений не внесено."
    rm -f /tmp/geoip.dat.new /tmp/geosite.dat.new
    exit 1
fi

# бэкап текущей geodata
mkdir -p "$BACKUP_DIR"
cp "$GEOIP" "$BACKUP_DIR/geoip.dat.backup" 2>/dev/null
cp "$GEOSITE" "$BACKUP_DIR/geosite.dat.backup" 2>/dev/null

# замена
mv /tmp/geoip.dat.new "$GEOIP"
mv /tmp/geosite.dat.new "$GEOSITE"
echo "geodata обновлена (geoip=$SIZE_IP, geosite=$SIZE_SITE байт)."

# проверка конфига с новой geodata
if XRAY_LOCATION_ASSET="$SHARE" /opt/xray/bin/xray -test -config /opt/xray/config/client.json >/dev/null 2>&1; then
    "$SERVICE" restart >/dev/null 2>&1
    echo "Проверка пройдена, сервис перезапущен."
    echo "Подождите 30-60 секунд и проверьте доступ в интернет."
else
    echo "ОШИБКА: конфиг не проходит проверку с новой geodata. Откатываю..."
    cp "$BACKUP_DIR/geoip.dat.backup" "$GEOIP" 2>/dev/null
    cp "$BACKUP_DIR/geosite.dat.backup" "$GEOSITE" 2>/dev/null
    "$SERVICE" restart >/dev/null 2>&1
    echo "Откат geodata выполнен."
    exit 1
fi
