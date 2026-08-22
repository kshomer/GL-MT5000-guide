#!/bin/sh
# xray-route.sh — управление пользовательскими исключениями маршрутизации Xray (через jq).
#
# Команды:
#   add-proxy  <домен>   добавить домен в исключения "через туннель" (VPN)
#   add-direct <домен>   добавить домен в исключения "напрямую" (мимо VPN)
#   del        <домен>   удалить домен из исключений (из любого списка)
#   list                 показать все текущие исключения
#
# Каждое изменение: правит client.json через jq, валидирует через xray -test,
# при успехе перезапускает сервис, при ошибке откатывает.

CONFIG="/opt/xray/config/client.json"
XRAY_BIN="/opt/xray/bin/xray"
XRAY_ASSET="/opt/xray/share"
SERVICE="/etc/init.d/xray-tproxy"
BACKUP="/tmp/xray-route-backup.json"
TMP="/tmp/xray-route-tmp.json"

CMD="$1"
DOMAIN="$2"

usage() {
    echo "Использование:"
    echo "  $0 add-proxy  <домен>   — домен через туннель (VPN)"
    echo "  $0 add-direct <домен>   — домен напрямую (мимо VPN)"
    echo "  $0 del        <домен>   — удалить домен из исключений"
    echo "  $0 list                 — показать исключения"
    exit 1
}

normalize() {
    echo "$1" | tr 'A-Z' 'a-z' | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|[[:space:]]||g'
}

if [ "$CMD" = "list" ]; then
    echo "=== Через туннель (proxy) ==="
    P=$(jq -r '.routing.rules[] | select(.ruleTag=="user-proxy").domain[] | select(endswith(".invalid")|not)' "$CONFIG" 2>/dev/null)
    [ -n "$P" ] && echo "$P" | sed 's/^/  /' || echo "  (пусто)"
    echo "=== Напрямую (direct) ==="
    D=$(jq -r '.routing.rules[] | select(.ruleTag=="user-direct").domain[] | select(endswith(".invalid")|not)' "$CONFIG" 2>/dev/null)
    [ -n "$D" ] && echo "$D" | sed 's/^/  /' || echo "  (пусто)"
    exit 0
fi

[ -z "$DOMAIN" ] && usage
DOMAIN=$(normalize "$DOMAIN")
[ -z "$DOMAIN" ] && { echo "Пустой домен после нормализации."; exit 1; }

cp "$CONFIG" "$BACKUP"

case "$CMD" in
    add-proxy)
        jq --arg d "$DOMAIN" '
          (.routing.rules[] | select(.ruleTag=="user-direct").domain) |=
            (map(select(. != $d)) | if length==0 then ["placeholder-direct.invalid"] else . end)
          | (.routing.rules[] | select(.ruleTag=="user-proxy").domain) |=
            (if (index($d)) then . else . + [$d] end)
        ' "$CONFIG" > "$TMP"
        ;;
    add-direct)
        jq --arg d "$DOMAIN" '
          (.routing.rules[] | select(.ruleTag=="user-proxy").domain) |=
            (map(select(. != $d)) | if length==0 then ["placeholder-proxy.invalid"] else . end)
          | (.routing.rules[] | select(.ruleTag=="user-direct").domain) |=
            (if (index($d)) then . else . + [$d] end)
        ' "$CONFIG" > "$TMP"
        ;;
    del)
        jq --arg d "$DOMAIN" '
          (.routing.rules[] | select(.ruleTag=="user-proxy").domain) |=
            (map(select(. != $d)) | if length==0 then ["placeholder-proxy.invalid"] else . end)
          | (.routing.rules[] | select(.ruleTag=="user-direct").domain) |=
            (map(select(. != $d)) | if length==0 then ["placeholder-direct.invalid"] else . end)
        ' "$CONFIG" > "$TMP"
        ;;
    *) usage ;;
esac

if [ ! -s "$TMP" ] || ! jq empty "$TMP" >/dev/null 2>&1; then
    echo "Ошибка: jq не смог обработать конфиг. Изменений не внесено."
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$CONFIG"

if XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" -test -config "$CONFIG" >/dev/null 2>&1; then
    "$SERVICE" restart >/dev/null 2>&1
    echo "Готово: '$DOMAIN' ($CMD). Сервис перезапущен."
    sleep 2
    echo "--- текущие исключения ---"
    sh "$0" list
else
    echo "Ошибка: xray -test не прошёл, откатываю."
    cp "$BACKUP" "$CONFIG"
    exit 1
fi
