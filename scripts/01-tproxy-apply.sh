#!/bin/sh
# tproxy-apply.sh — идемпотентное применение tproxy-правил + QUIC-блок + policy-routing.
# Сначала чистит старое (если было), потом ставит заново. Безопасно запускать повторно.
#
# Адрес сервера берётся ДИНАМИЧЕСКИ из client.json (outbound proxy) — не захардкожен.
# Поддерживаются оба варианта: IP (Reality) и домен (XHTTP+TLS) — домен резолвится в IP,
# т.к. iptables принимает только адреса. При смене IP домена достаточно перезапустить сервис.
# При смене сервера через скрипт достаточно поменять конфиг: этот скрипт сам подхватит новый IP.
#
# Перехват ограничен ЯВНО ЗАДАННЫМИ интерфейсами (br-lan + wg0): трафик прочих интерфейсов
# (WAN, будущие VPN/оверлеи вроде tailscale0) в капкан НЕ попадает. Урок инцидента
# с Tailscale exit node: перехват «со всех интерфейсов» завалил Xray лавиной потоков (OOM).
#
# Также вычищает мёртвые TIME_WAIT-соединения к серверу: при частых рестартах с активным
# трафиком они накапливаются (Vision открывает TCP на каждый поток) и могут исчерпать пул
# исходящих портов к серверу -> туннель не поднимается. Очистка TIME_WAIT это предотвращает.
# ESTABLISHED-соединения НЕ трогаются (удаляется только состояние TIME_WAIT).

CONFIG="/opt/xray/config/client.json"
TPROXY_PORT="12345"
MARK="1"
TABLE="100"
LAN_IF="br-lan"
WG_IF="wg0"          # WireGuard-сервер (клиенты извне: доступ к дому + обход блокировок через Xray)

### 0. ДОСТАЁМ АДРЕС СЕРВЕРА ИЗ КОНФИГА ###
# В конфиге может быть как IP (Reality/прямое подключение), так и ДОМЕН (XHTTP+TLS).
# Для iptables нужен именно IP — домен резолвим.
SERVER_ADDR=$(jq -r '.outbounds[] | select(.tag=="proxy") | .settings.vnext[0].address' "$CONFIG" 2>/dev/null)

# если адрес — не IPv4, считаем его доменом и резолвим
if echo "$SERVER_ADDR" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    SERVER_IP="$SERVER_ADDR"
else
    echo "[tproxy-apply] Адрес сервера — домен ($SERVER_ADDR), резолвим в IP ..."
    # резолвим через локальный DNS; берём первый A-ответ
    SERVER_IP=$(nslookup "$SERVER_ADDR" 127.0.0.1 2>/dev/null | awk '/^Address [0-9]*: /{print $3; exit}')
    # запасной вариант: системный резолвер
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(nslookup "$SERVER_ADDR" 2>/dev/null | awk '/^Address [0-9]*: /{print $3; exit}')
    fi
    if [ -n "$SERVER_IP" ]; then
        echo "[tproxy-apply] $SERVER_ADDR -> $SERVER_IP"
    fi
fi

# защита: если IP не извлёкся — НЕ применяем правила (иначе трафик к серверу зациклится)
if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "null" ]; then
    echo "[tproxy-apply] ОШИБКА: не удалось определить IP сервера (конфиг: $CONFIG, адрес: $SERVER_ADDR)."
    echo "[tproxy-apply] Правила НЕ применены (во избежание петли трафика)."
    exit 1
fi

echo "[tproxy-apply] IP сервера из конфига: $SERVER_IP"

### 0b. ОЧИСТКА мёртвых TIME_WAIT-соединений к серверу ###
# освобождает исходящие порты (защита от накопления при частых рестартах с трафиком)
if command -v conntrack >/dev/null 2>&1; then
    conntrack -D -d "$SERVER_IP" -p tcp --state TIME_WAIT >/dev/null 2>&1
fi

### 1. ОЧИСТКА старого (обе формы джампа: старая без интерфейса и новая с -i br-lan) ###
iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null
iptables -t mangle -D PREROUTING -i "$LAN_IF" -j XRAY 2>/dev/null
iptables -t mangle -D PREROUTING -i "$WG_IF" -j XRAY 2>/dev/null
iptables -t mangle -F XRAY 2>/dev/null
iptables -t mangle -X XRAY 2>/dev/null
iptables -t raw -D PREROUTING -i "$LAN_IF" -p udp --dport 443 -j DROP 2>/dev/null
ip rule del fwmark $MARK table $TABLE 2>/dev/null
ip route flush table $TABLE 2>/dev/null

### 2. POLICY-ROUTING ###
ip rule add fwmark $MARK table $TABLE
ip route add local 0.0.0.0/0 dev lo table $TABLE

### 3. TPROXY-ЦЕПОЧКА (mangle) ###
iptables -t mangle -N XRAY
# исключения — локальные/служебные сети идут напрямую (защита SSH/LAN)
iptables -t mangle -A XRAY -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A XRAY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A XRAY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A XRAY -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A XRAY -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A XRAY -d 240.0.0.0/4 -j RETURN
# исключение для СЕРВЕРА (динамически из конфига) — иначе петля туннеля
iptables -t mangle -A XRAY -d ${SERVER_IP}/32 -j RETURN
# перехват остального TCP/UDP в tproxy
iptables -t mangle -A XRAY -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK
iptables -t mangle -A XRAY -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK
# подключение цепочки к PREROUTING — ТОЛЬКО для трафика из LAN
iptables -t mangle -A PREROUTING -i "$LAN_IF" -j XRAY
# подключение цепочки для WireGuard-клиентов (если интерфейс поднят):
# трафик телефона/ноутбука извне идёт через Xray -> загран открывается, РФ напрямую.
if ip link show "$WG_IF" >/dev/null 2>&1; then
    iptables -t mangle -A PREROUTING -i "$WG_IF" -j XRAY
    WG_STATUS=" + $WG_IF"
else
    WG_STATUS=""
fi

### 4. QUIC-БЛОК (raw/PREROUTING) ###
iptables -t raw -I PREROUTING -i "$LAN_IF" -p udp --dport 443 -j DROP

echo "[tproxy-apply] Правила применены: tproxy ($LAN_IF$WG_STATUS) + QUIC-блок + policy-routing (исключение сервера: $SERVER_IP)."
