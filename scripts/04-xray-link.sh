#!/bin/sh
# xray-link.sh — смена VPN-сервера по vless-ссылке.
#
# Поддерживает ОБА транспорта:
#   - VLESS + TCP + Reality (+ Vision)      security=reality
#   - VLESS + TLS: xhttp / ws / grpc / tcp  security=tls
#
# outbound "proxy" пересобирается целиком по типу ссылки, а не патчится по
# отдельным полям — это исключает нерабочий гибрид при смене транспорта:
# если бы Reality-поля дописывались поверх XHTTP-конфига, остались бы
# security=tls рядом с realitySettings и старые xhttpSettings — TCP
# соединялся бы, а рукопожатие рвалось (CLOSE_WAIT).
#
# Остальная часть конфига (inbound tproxy, routing, dns, direct/block) не трогается.
#
# fingerprint: по умолчанию "randomized". Это осознанный выбор — на этом роутере
# fingerprint "chrome" доказанно ломает связку под нагрузкой (выяснено при отладке
# Reality). Переопределить можно флагом --fp=<значение>, если нужно.

CONFIG="/opt/xray/config/client.json"
BACKUP="/opt/xray/config/client.json.prev"
XRAY_BIN="/opt/xray/bin/xray"
XRAY_ASSET="/opt/xray/share"
SERVICE="/etc/init.d/xray-tproxy"
DEFAULT_FP="randomized"
WAIT_TUNNEL=45          # сколько секунд ждать появления первого соединения
WARMUP=40               # сколько ещё ждать прогрева туннеля после первого соединения
MIN_EST=5               # столько соединений считаем признаком готового туннеля

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()   { printf "${G}[OK]${N} %s\n" "$1"; }
info() { printf "${C}[i]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[ОШИБКА]${N} %s\n" "$1"; exit 1; }

### --- вспомогательное --- ###

urldecode() {
    [ -z "$1" ] && return
    printf '%b' "$(echo "$1" | sed 's/+/ /g; s/%/\\x/g')"
}

qparam() {
    echo "$QUERY" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2-
}

resolve_ip() {
    if echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$1"
    else
        nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Address [0-9]*: /{print $3; exit}'
    fi
}

jqp() { jq -r ".outbounds[]|select(.tag==\"proxy\")|$1" "$CONFIG" 2>/dev/null; }

# ждём поднятия туннеля к $1, возвращаем число соединений в переменной EST.
#
# Reality/XHTTP на этом роутере разворачиваются 30-60 сек. Важно: появление
# первого соединения ещё не значит, что туннель готов — при 1-3 соединениях
# трафик клиентов обычно не идёт, при 5+ уже работает (проверено). Поэтому:
# ждём первое соединение, затем даём прогреться и подтверждаем, что их стало
# достаточно.
wait_tunnel() {
    _ip="$1"; _i=0; EST=0

    # фаза 1 — ждём первое соединение
    while [ $_i -lt $WAIT_TUNNEL ]; do
        sleep 5; _i=$((_i + 5))
        EST=$(conntrack -L 2>/dev/null | grep "$_ip" | grep -c ESTABLISHED)
        [ "$EST" -gt 0 ] && break
        printf "."
    done

    # фаза 2 — прогрев: ждём, пока соединений станет достаточно
    if [ "$EST" -gt 0 ] && [ "$EST" -lt "$MIN_EST" ]; then
        printf " прогрев"
        _w=0
        while [ $_w -lt $WARMUP ]; do
            sleep 5; _w=$((_w + 5))
            EST=$(conntrack -L 2>/dev/null | grep "$_ip" | grep -c ESTABLISHED)
            [ "$EST" -ge "$MIN_EST" ] && break
            printf "."
        done
    fi
    echo ""
}

### --- показать текущий конфиг --- ###

cmd_show() {
    ADDR=$(jqp '.settings.vnext[0].address')
    PORT=$(jqp '.settings.vnext[0].port')
    NET=$(jqp '.streamSettings.network')
    SEC=$(jqp '.streamSettings.security')
    FLOW=$(jqp '.settings.vnext[0].users[0].flow // "—"')

    printf "${C}=== Текущий сервер ===${N}\n"
    echo "  адрес:       $ADDR:$PORT"
    echo "  транспорт:   $NET / $SEC"
    echo "  flow:        $FLOW"

    case "$SEC" in
      reality)
        echo "  SNI:         $(jqp '.streamSettings.realitySettings.serverName')"
        echo "  fingerprint: $(jqp '.streamSettings.realitySettings.fingerprint')"
        ;;
      tls)
        echo "  SNI:         $(jqp '.streamSettings.tlsSettings.serverName')"
        echo "  fingerprint: $(jqp '.streamSettings.tlsSettings.fingerprint // "—"')"
        case "$NET" in
            xhttp) echo "  path:        $(jqp '.streamSettings.xhttpSettings.path')"
                   echo "  mode:        $(jqp '.streamSettings.xhttpSettings.mode')" ;;
            ws)    echo "  path:        $(jqp '.streamSettings.wsSettings.path')" ;;
            grpc)  echo "  service:     $(jqp '.streamSettings.grpcSettings.serviceName')" ;;
        esac
        ;;
    esac

    echo ""
    if ps w | grep '[x]ray' | grep -q client.json; then
        SRV_IP=$(resolve_ip "$ADDR")
        [ -n "$SRV_IP" ] || SRV_IP="$ADDR"
        EST=$(conntrack -L 2>/dev/null | grep "$SRV_IP" | grep -c ESTABLISHED)
        if [ "$EST" -gt 0 ]; then
            ok "Xray запущен,активных соединений к серверу: $EST"
        else
            warn "Xray запущен, но активных соединений к серверу нет"
        fi
    else
        warn "Xray НЕ запущен"
    fi
    [ -f "$BACKUP" ] && info "есть предыдущий конфиг: xray-link rollback"
    return 0
}

### --- откат --- ###

cmd_rollback() {
    [ -f "$BACKUP" ] || err "предыдущего конфига нет ($BACKUP)"
    cp "$CONFIG" "$CONFIG.failed" 2>/dev/null
    cp "$BACKUP" "$CONFIG"
    ok "конфиг возвращён из $BACKUP"
    info "перезапуск сервиса ..."
    $SERVICE restart >/dev/null 2>&1

    RB_ADDR=$(jqp '.settings.vnext[0].address')
    RB_IP=$(resolve_ip "$RB_ADDR"); [ -n "$RB_IP" ] || RB_IP="$RB_ADDR"
    info "ждём туннель к $RB_IP (до ${WAIT_TUNNEL} сек) ..."
    wait_tunnel "$RB_IP"

    if [ "$EST" -gt 0 ]; then
        ok "туннель поднялся (соединений: $EST)"
    else
        warn "туннель пока не поднялся"
        warn "при частых перезапусках подряд Xray иногда требует ещё одного:"
        warn "  /etc/init.d/xray-tproxy restart   (затем подождать ~45 сек)"
    fi
    echo ""
    cmd_show
}

### --- смена сервера --- ###

cmd_set() {
    LINK="$1"
    echo "$LINK" | grep -q '^vless://' || err "ссылка должна начинаться с vless://"

    BODY=${LINK#vless://}
    TAG=$(echo "$BODY" | sed -n 's/.*#//p')
    BODY=${BODY%%#*}

    UUID=${BODY%%@*}
    REST=${BODY#*@}
    HOSTPORT=${REST%%\?*}
    QUERY=${REST#*\?}
    [ "$QUERY" = "$REST" ] && QUERY=""

    ADDR=${HOSTPORT%%:*}
    PORT=${HOSTPORT##*:}

    [ -n "$UUID" ] || err "не удалось извлечь UUID"
    [ -n "$ADDR" ] || err "не удалось извлечь адрес сервера"
    echo "$PORT" | grep -qE '^[0-9]+$' || err "некорректный порт: $PORT"

    SEC=$(qparam security); [ -n "$SEC" ] || SEC="none"
    NET=$(qparam type);     [ -n "$NET" ] || NET="tcp"
    SNI=$(qparam sni)
    FLOW=$(qparam flow)
    PBK=$(qparam pbk)
    SID=$(qparam sid)
    SPX=$(urldecode "$(qparam spx)"); [ -n "$SPX" ] || SPX="/"
    PATH_Q=$(urldecode "$(qparam path)")
    HOST_H=$(qparam host)
    MODE=$(qparam mode);    [ -n "$MODE" ] || MODE="auto"
    SVCNAME=$(urldecode "$(qparam serviceName)")

    if [ -n "$FP_OVERRIDE" ]; then
        FP="$FP_OVERRIDE"; FPNOTE=" (задан вручную)"
    else
        FP="$DEFAULT_FP"; FPNOTE=" (по умолчанию; fp из ссылки игнорируется — см. шапку скрипта)"
    fi

    [ -n "$SNI" ] || SNI="$ADDR"
    [ -n "$HOST_H" ] || HOST_H="$SNI"

    printf "${C}=== Распознано ===${N}\n"
    echo "  адрес:       $ADDR:$PORT"
    echo "  транспорт:   $NET / $SEC"
    echo "  SNI:         $SNI"
    echo "  fingerprint: $FP$FPNOTE"
    [ -n "$TAG" ] && echo "  метка:       $TAG"

    case "$SEC" in
      reality)
        [ -n "$PBK" ] || err "для Reality нужен параметр pbk (publicKey)"
        [ -n "$SID" ] || err "для Reality нужен параметр sid (shortId)"
        [ "$NET" = "tcp" ] || warn "Reality обычно идёт с type=tcp (в ссылке: $NET)"
        [ -n "$FLOW" ] && echo "  flow:        $FLOW"
        STREAM=$(jq -n --arg net "$NET" --arg sni "$SNI" --arg fp "$FP" \
                       --arg pbk "$PBK" --arg sid "$SID" --arg spx "$SPX" '{
            network: $net, security: "reality",
            realitySettings: { serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, spiderX:$spx }
        }')
        ;;
      tls)
        case "$NET" in
          xhttp)
            [ -n "$PATH_Q" ] || err "для XHTTP нужен параметр path"
            echo "  path:        $PATH_Q"
            echo "  mode:        $MODE"
            STREAM=$(jq -n --arg sni "$SNI" --arg fp "$FP" --arg host "$HOST_H" \
                           --arg path "$PATH_Q" --arg mode "$MODE" '{
                network: "xhttp", security: "tls",
                tlsSettings: { serverName:$sni, fingerprint:$fp, allowInsecure:false },
                xhttpSettings: { host:$host, path:$path, mode:$mode }
            }')
            [ -n "$FLOW" ] && { warn "flow не применяется к XHTTP — игнорирую"; FLOW=""; }
            ;;
          ws)
            [ -n "$PATH_Q" ] || PATH_Q="/"
            echo "  path:        $PATH_Q"
            STREAM=$(jq -n --arg sni "$SNI" --arg fp "$FP" --arg host "$HOST_H" --arg path "$PATH_Q" '{
                network: "ws", security: "tls",
                tlsSettings: { serverName:$sni, fingerprint:$fp, allowInsecure:false },
                wsSettings: { path:$path, headers:{ Host:$host } }
            }')
            [ -n "$FLOW" ] && { warn "flow не применяется к WebSocket — игнорирую"; FLOW=""; }
            ;;
          grpc)
            [ -n "$SVCNAME" ] || err "для gRPC нужен параметр serviceName"
            echo "  service:     $SVCNAME"
            STREAM=$(jq -n --arg sni "$SNI" --arg fp "$FP" --arg svc "$SVCNAME" '{
                network: "grpc", security: "tls",
                tlsSettings: { serverName:$sni, fingerprint:$fp, allowInsecure:false },
                grpcSettings: { serviceName:$svc }
            }')
            [ -n "$FLOW" ] && { warn "flow не применяется к gRPC — игнорирую"; FLOW=""; }
            ;;
          tcp)
            [ -n "$FLOW" ] && echo "  flow:        $FLOW"
            STREAM=$(jq -n --arg sni "$SNI" --arg fp "$FP" '{
                network: "tcp", security: "tls",
                tlsSettings: { serverName:$sni, fingerprint:$fp, allowInsecure:false }
            }')
            ;;
          *) err "неподдерживаемый транспорт для TLS: $NET" ;;
        esac
        ;;
      *) err "неподдерживаемый security: '$SEC' (ожидается reality или tls)" ;;
    esac

    if [ -n "$FLOW" ]; then
        USERJSON=$(jq -n --arg id "$UUID" --arg flow "$FLOW" '{id:$id, encryption:"none", flow:$flow}')
    else
        USERJSON=$(jq -n --arg id "$UUID" '{id:$id, encryption:"none"}')
    fi

    ### ПОЛНАЯ пересборка outbound proxy ###
    NEWCFG=$(jq --arg addr "$ADDR" --argjson port "$PORT" \
                --argjson user "$USERJSON" --argjson stream "$STREAM" '
        (.outbounds[] | select(.tag=="proxy")) = {
            tag: "proxy",
            protocol: "vless",
            settings: { vnext: [ { address:$addr, port:$port, users:[ $user ] } ] },
            streamSettings: $stream
        }' "$CONFIG") || err "не удалось собрать конфиг"

    echo "$NEWCFG" | jq empty 2>/dev/null || err "получился невалидный JSON — изменений не внесено"
    echo "$NEWCFG" > /tmp/xray-link-new.json

    if XRAY_LOCATION_ASSET="$XRAY_ASSET" "$XRAY_BIN" -test -config /tmp/xray-link-new.json >/dev/null 2>&1; then
        ok "конфиг проверен Xray — валиден"
    else
        info "проверка через xray -test недоступна, полагаемся на проверку туннеля"
    fi

    cp "$CONFIG" "$BACKUP"
    cp /tmp/xray-link-new.json "$CONFIG"
    rm -f /tmp/xray-link-new.json
    ok "конфиг применён (предыдущий сохранён: $BACKUP)"

    info "перезапуск сервиса ..."
    $SERVICE restart >/dev/null 2>&1

    SRV_IP=$(resolve_ip "$ADDR")
    [ -n "$SRV_IP" ] || SRV_IP="$ADDR"
    info "ждём туннель к $SRV_IP (до ${WAIT_TUNNEL} сек) ..."

    wait_tunnel "$SRV_IP"

    if [ "$EST" -ge "$MIN_EST" ]; then
        ok "туннель поднялся и прогрелся (соединений: $EST)"
        echo ""
        info "можно проверять доступ в интернет с устройства"
        info "если что-то не так — откат: xray-link rollback"
    elif [ "$EST" -gt 0 ]; then
        ok "туннель поднялся, но прогрет слабо (соединений: $EST)"
        echo ""
        warn "подождите ещё 30-60 сек перед проверкой — туннель дозреет сам"
        info "если через минуту не заработает — откат: xray-link rollback"
    else
        warn "туннель не поднялся за ${WAIT_TUNNEL} сек — АВТООТКАТ"
        cp "$CONFIG" "$CONFIG.failed"
        cp "$BACKUP" "$CONFIG"
        $SERVICE restart >/dev/null 2>&1
        PREV_ADDR=$(jqp '.settings.vnext[0].address')
        PREV_IP=$(resolve_ip "$PREV_ADDR"); [ -n "$PREV_IP" ] || PREV_IP="$PREV_ADDR"
        info "ждём возврата туннеля к $PREV_IP ..."
        wait_tunnel "$PREV_IP"
        ok "откат выполнен, вернулся предыдущий сервер (соединений: $EST)"
        info "нерабочий конфиг сохранён для разбора: $CONFIG.failed"
        exit 1
    fi
}

usage() {
    cat << 'HELPEOF'
xray-link — смена VPN-сервера по vless-ссылке (Reality и TLS)

  xray-link                        показать текущий сервер и статус
  xray-link show                   то же
  xray-link "vless://..."          сменить сервер (ссылка В КАВЫЧКАХ!)
  xray-link --fp=<fp> "vless://…"  сменить + задать fingerprint вручную
  xray-link rollback               вернуть предыдущий конфиг

Поддерживаемые транспорты:
  security=reality + type=tcp     (нужны pbk и sid)
  security=tls     + type=xhttp   (нужен path)
  security=tls     + type=ws      (path, по умолчанию /)
  security=tls     + type=grpc    (нужен serviceName)
  security=tls     + type=tcp

Особенности:
  - outbound пересобирается ПОЛНОСТЬЮ: при смене транспорта (Reality <-> TLS)
    старые настройки не остаются и не создают нерабочий гибрид;
  - flow (xtls-rprx-vision) ставится только для tcp; для xhttp/ws/grpc игнорируется;
  - fingerprint по умолчанию randomized (chrome ломает связку на этом роутере
    под нагрузкой); переопределяется флагом --fp=;
  - после применения ждёт туннель, при неудаче откатывается автоматически;
  - tproxy сам подхватывает новый адрес сервера (в т.ч. домен — резолвит в IP);
  - остальная часть конфига (tproxy-inbound, routing, dns) не изменяется.

Если после нескольких переключений подряд туннель не поднимается — сделайте
  /etc/init.d/xray-tproxy restart   и подождите ~45 сек. Частые рестарты подряд
иногда оставляют Xray в состоянии, из которого помогает выйти лишний перезапуск.
HELPEOF
}

FP_OVERRIDE=""
ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fp=*) FP_OVERRIDE="${1#*=}"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) ARG="$1"; shift ;;
    esac
done

command -v jq >/dev/null 2>&1 || err "нужен jq"
[ -f "$CONFIG" ] || err "конфиг не найден: $CONFIG"

case "$ARG" in
    ""|show)   cmd_show ;;
    rollback)  cmd_rollback ;;
    vless://*) cmd_set "$ARG" ;;
    *)         err "неизвестный аргумент: $ARG (см. xray-link --help)" ;;
esac
