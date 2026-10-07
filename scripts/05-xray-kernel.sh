#!/bin/sh
# xray-kernel.sh — безопасная смена версии ядра Xray на роутере MT5000.
#
# Использование:
#   xray-kernel update <версия>   скачать версию с GitHub, проверить, поставить (напр. update 26.6.22)
#   xray-kernel rollback          откатить на предыдущую версию (из бэкапа)
#   xray-kernel show              показать текущую версию
#
# После смены/отката выполняется АКТИВНАЯ ПРОВЕРКА ТУННЕЛЯ (пробное соединение через сервер).
# Если туннель не поднялся — скрипт делает повторный restart и проверяет снова (до 3 попыток).
# geodata НЕ трогается (независима от версии ядра).

BIN="/opt/xray/bin/xray"
BACKUP="/opt/xray/bin/xray.backup"
CONFIG="/opt/xray/config/client.json"
XRAY_ASSET="/opt/xray/share"
SERVICE="/etc/init.d/xray-tproxy"
TMPZIP="/tmp/xray-kernel-dl.zip"
TMPDIR="/tmp/xray-kernel-dl"

WAIT_RULES=12       # ожидание применения tproxy-правил (сервис ставит их через ~8 сек)
CHECK_PORT=10820    # временный порт для проверки туннеля
CHECK_URL="https://www.google.com"
MAX_TRIES=3         # сколько раз пробовать (restart + проверка) при неудаче

CMD="$1"
VER="$2"

usage() {
    echo "Использование:"
    echo "  xray-kernel update <версия>   скачать и поставить версию (напр. update 26.6.22)"
    echo "  xray-kernel rollback          откат на предыдущую версию"
    echo "  xray-kernel show              показать текущую версию"
    echo
    echo "Версии смотреть тут: https://github.com/XTLS/Xray-core/releases"
    exit 1
}

xray_running() {
    ps w | grep '[x]ray' | grep -q client.json
}

# --- активная проверка туннеля: поднимает временный socks через боевой сервер ---
# возвращает 0 если туннель работает (google отвечает 200), иначе 1
tunnel_ok() {
    ADDR=$(jq -r '.outbounds[]|select(.tag=="proxy")|.settings.vnext[0].address' "$CONFIG")
    SPORT=$(jq -r '.outbounds[]|select(.tag=="proxy")|.settings.vnext[0].port' "$CONFIG")
    UUID=$(jq -r '.outbounds[]|select(.tag=="proxy")|.settings.vnext[0].users[0].id' "$CONFIG")
    FLOW=$(jq -r '.outbounds[]|select(.tag=="proxy")|.settings.vnext[0].users[0].flow' "$CONFIG")
    SNI=$(jq -r '.outbounds[]|select(.tag=="proxy")|.streamSettings.realitySettings.serverName' "$CONFIG")
    PBK=$(jq -r '.outbounds[]|select(.tag=="proxy")|.streamSettings.realitySettings.publicKey' "$CONFIG")
    SID=$(jq -r '.outbounds[]|select(.tag=="proxy")|.streamSettings.realitySettings.shortId' "$CONFIG")

    jq -n --arg addr "$ADDR" --argjson sport "$SPORT" --arg uuid "$UUID" --arg flow "$FLOW" \
          --arg sni "$SNI" --arg pbk "$PBK" --arg sid "$SID" --argjson port "$CHECK_PORT" '
    {
      log:{loglevel:"warning"},
      inbounds:[{tag:"socks",port:$port,listen:"127.0.0.1",protocol:"socks",settings:{udp:false}}],
      outbounds:[{tag:"proxy",protocol:"vless",
        settings:{vnext:[{address:$addr,port:$sport,users:[{id:$uuid,encryption:"none",flow:$flow}]}]},
        streamSettings:{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:"randomized",publicKey:$pbk,shortId:$sid}}}]
    }' > /tmp/tuncheck.json 2>/dev/null

    XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BIN" run -config /tmp/tuncheck.json > /tmp/tuncheck.log 2>&1 &
    TPID=$!
    sleep 4
    CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" --max-time 12 --socks5-hostname 127.0.0.1:$CHECK_PORT "$CHECK_URL" 2>/dev/null)
    kill $TPID 2>/dev/null
    rm -f /tmp/tuncheck.json /tmp/tuncheck.log
    [ "$CODE" = "200" ]
}

# --- проверка с автоповтором: после рестарта ждём правила, проверяем туннель,
#     при неудаче делаем restart и пробуем снова (до MAX_TRIES) ---
verify_with_retry() {
    try=1
    while [ $try -le $MAX_TRIES ]; do
        echo "Ожидание применения правил (попытка $try из $MAX_TRIES)..."
        sleep $WAIT_RULES
        if ! xray_running; then
            echo "  Xray не запущен, перезапуск..."
            "$SERVICE" restart >/dev/null 2>&1
            try=$((try+1))
            continue
        fi
        echo "  Xray запущен. Проверка туннеля..."
        if tunnel_ok; then
            echo "  Туннель работает (проверено через сервер)."
            return 0
        fi
        echo "  Туннель пока не отвечает."
        if [ $try -lt $MAX_TRIES ]; then
            echo "  Повторный перезапуск сервиса..."
            "$SERVICE" restart >/dev/null 2>&1
        fi
        try=$((try+1))
    done
    return 1
}

# --- SHOW ---
if [ "$CMD" = "show" ] || [ -z "$CMD" ]; then
    echo "=== Текущая версия ядра ==="
    XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BIN" version 2>/dev/null | head -1 || echo "не удалось определить"
    if [ -f "$BACKUP" ]; then
        echo "=== Версия в бэкапе (для отката) ==="
        XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BACKUP" version 2>/dev/null | head -1 || echo "бэкап повреждён"
    else
        echo "(бэкапа нет — откат недоступен, пока не было ни одной смены)"
    fi
    exit 0
fi

# --- ROLLBACK ---
if [ "$CMD" = "rollback" ]; then
    if [ ! -f "$BACKUP" ]; then
        echo "Ошибка: бэкап $BACKUP не найден. Откат невозможен."
        exit 1
    fi
    CURVER=$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BIN" version 2>/dev/null | head -1)
    BAKVER=$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BACKUP" version 2>/dev/null | head -1)
    echo "Текущая версия: $CURVER"
    echo "Откат на:       $BAKVER"
    echo
    if ! XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BACKUP" -test -config "$CONFIG" >/dev/null 2>&1; then
        echo "Ошибка: бэкап не проходит проверку с текущим конфигом. Откат отменён."
        exit 1
    fi
    cp "$BACKUP" "$BIN"
    chmod +x "$BIN"
    "$SERVICE" restart >/dev/null 2>&1
    echo "Бинарь возвращён."
    if verify_with_retry; then
        RUNVER=$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BIN" version 2>/dev/null | head -1)
        echo
        echo "Откат выполнен и туннель работает. Версия: $RUNVER"
    else
        echo
        echo "ВНИМАНИЕ: откат сделан, но туннель не поднялся за $MAX_TRIES попыток."
        echo "Попробуйте вручную: $SERVICE restart (и подождите ~30 сек)."
        exit 1
    fi
    exit 0
fi

# --- UPDATE ---
if [ "$CMD" != "update" ]; then
    usage
fi
[ -z "$VER" ] && { echo "Ошибка: не указана версия."; echo; usage; }

VER=$(echo "$VER" | sed 's/^v//')
URL="https://github.com/XTLS/Xray-core/releases/download/v${VER}/Xray-linux-arm64-v8a.zip"

echo "=== Смена ядра Xray на версию $VER ==="
CURVER=$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BIN" version 2>/dev/null | head -1)
echo "  Текущая версия: $CURVER"
echo "  Скачиваю: $URL"

rm -f "$TMPZIP"; rm -rf "$TMPDIR"
if ! curl -fsSL --max-time 120 -o "$TMPZIP" "$URL"; then
    echo "Ошибка: не удалось скачать версию $VER."
    echo "Проверьте, что версия существует: https://github.com/XTLS/Xray-core/releases"
    rm -f "$TMPZIP"
    exit 1
fi

SIZE=$(wc -c < "$TMPZIP")
if [ "$SIZE" -lt 500000 ]; then
    echo "Ошибка: скачанный файл подозрительно мал ($SIZE байт). Возможно, версии $VER не существует."
    rm -f "$TMPZIP"
    exit 1
fi

mkdir -p "$TMPDIR"
if ! unzip -o "$TMPZIP" xray -d "$TMPDIR" >/dev/null 2>&1; then
    echo "Ошибка: не удалось распаковать бинарь из архива."
    rm -f "$TMPZIP"; rm -rf "$TMPDIR"
    exit 1
fi
NEWBIN="$TMPDIR/xray"
chmod +x "$NEWBIN"

NEWVER=$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$NEWBIN" version 2>/dev/null | head -1)
if [ -z "$NEWVER" ]; then
    echo "Ошибка: скачанный бинарь не запускается (битый?). Замена НЕ произведена."
    rm -f "$TMPZIP"; rm -rf "$TMPDIR"
    exit 1
fi
echo "  Новая версия:   $NEWVER"

if ! XRAY_LOCATION_ASSET="$XRAY_ASSET" "$NEWBIN" -test -config "$CONFIG" >/dev/null 2>&1; then
    echo "Ошибка: новый бинарь не проходит проверку с боевым конфигом (-test)."
    echo "Возможно, версия несовместима. Замена НЕ произведена."
    rm -f "$TMPZIP"; rm -rf "$TMPDIR"
    exit 1
fi
echo "Проверки пройдены (version + test с конфигом)."

cp "$BIN" "$BACKUP"
chmod +x "$BACKUP"
echo "Текущий бинарь сохранён в бэкап."

cp "$NEWBIN" "$BIN"
chmod +x "$BIN"
echo "Новый бинарь установлен."

rm -f "$TMPZIP"; rm -rf "$TMPDIR"

"$SERVICE" restart >/dev/null 2>&1

if verify_with_retry; then
    RUNVER=$(XRAY_LOCATION_ASSET="$XRAY_ASSET" "$BIN" version 2>/dev/null | head -1)
    echo
    echo "Готово. Туннель работает. Версия: $RUNVER"
else
    echo
    echo "ОШИБКА: после установки $NEWVER туннель не поднялся за $MAX_TRIES попыток."
    echo "Выполняю АВТООТКАТ на предыдущую версию..."
    cp "$BACKUP" "$BIN"
    chmod +x "$BIN"
    "$SERVICE" restart >/dev/null 2>&1
    if verify_with_retry; then
        echo "Автооткат выполнен, туннель работает. Версия: $CURVER"
    else
        echo "КРИТИЧНО: даже после отката туннель не поднялся. Проверьте вручную:"
        echo "  $SERVICE restart ; ps w | grep xray"
    fi
    exit 1
fi
