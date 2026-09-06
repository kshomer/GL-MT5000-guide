#!/bin/sh
# wg-client.sh — управление клиентами WireGuard-сервера на GL-MT5000.
#
# Что делает:
#   add <имя>   — создаёт нового клиента: генерирует ключи, выбирает свободный IP,
#                 добавляет peer НА ЛЕТУ (без разрыва существующих подключений),
#                 сохраняет в UCI (переживает reboot), создаёт готовый .conf.
#   del <имя>   — удаляет клиента (из UCI, из живого интерфейса, файл конфига).
#   purge <имя> — стереть .conf с роутера (клиент продолжает работать).
#   list        — показывает всех клиентов, их IP и статус подключения.
#   qr <имя>    — печатает QR-код конфига (для телефонов/планшетов).
#   show <имя>  — показывает путь к .conf и команду скачивания на Mac.
#
# Клиенты получают:
#   - доступ к домашней сети (192.168.8.0/24),
#   - интернет через дом: загран через Xray (обход блокировок), РФ напрямую,
#   - DNS через AdGuard роутера (блокировка рекламы работает и вне дома).
#
# Конфиги клиентов: /etc/wireguard-manual/clients/<имя>.conf (права 600).

set -e

### НАСТРОЙКИ ###
WG_IF="wg0"
WG_SUBNET="10.0.100"              # подсеть WG (сервер = .1, клиенты с .2)
WG_PORT="51820"
ENDPOINT_HOST="<HOME_WHITE_IP>"    # белый статический IP от провайдера
BASE_DIR="/etc/wireguard-manual"
CLIENTS_DIR="$BASE_DIR/clients"
SERVER_PUB_FILE="$BASE_DIR/server_public.key"

### ЦВЕТА ###
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
ok()   { printf "${G}[OK]${N} %s\n" "$1"; }
info() { printf "${C}[i]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[ОШИБКА]${N} %s\n" "$1"; exit 1; }

### ПРОВЕРКИ ОКРУЖЕНИЯ ###
check_env() {
    command -v wg >/dev/null 2>&1 || err "утилита wg не найдена (нужен пакет wireguard-tools)"
    ip link show "$WG_IF" >/dev/null 2>&1 || err "интерфейс $WG_IF не поднят. Сначала настройте WG-сервер."
    [ -f "$SERVER_PUB_FILE" ] || err "не найден публичный ключ сервера: $SERVER_PUB_FILE"
    mkdir -p "$CLIENTS_DIR"
    chmod 700 "$CLIENTS_DIR"
}

### ПОИСК СВОБОДНОГО IP ###
# Проходит по 10.0.100.2 .. .254, возвращает первый не занятый в UCI.
find_free_ip() {
    i=2
    while [ $i -le 254 ]; do
        candidate="${WG_SUBNET}.${i}"
        if ! uci show network 2>/dev/null | grep -q "allowed_ips='${candidate}/32'"; then
            echo "$candidate"
            return 0
        fi
        i=$((i + 1))
    done
    err "свободных IP в подсети ${WG_SUBNET}.0/24 не осталось"
}

### ПОИСК ИНДЕКСА PEER ПО ИМЕНИ ###
find_peer_index() {
    name="$1"
    idx=0
    while uci get network.@wireguard_${WG_IF}[$idx] >/dev/null 2>&1; do
        desc=$(uci get network.@wireguard_${WG_IF}[$idx].description 2>/dev/null || echo "")
        if [ "$desc" = "$name" ]; then
            echo "$idx"
            return 0
        fi
        idx=$((idx + 1))
    done
    return 1
}

### ДОБАВЛЕНИЕ КЛИЕНТА ###
cmd_add() {
    name="$1"
    [ -n "$name" ] || err "укажите имя клиента: wg-client add <имя>"
    echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$' || err "имя может содержать только латиницу, цифры, дефис, подчёркивание"

    if find_peer_index "$name" >/dev/null 2>&1; then
        err "клиент '$name' уже существует. Удалите его (wg-client del $name) или выберите другое имя."
    fi

    client_ip=$(find_free_ip)
    info "имя: $name, назначенный IP: $client_ip"

    # генерация ключей во временных файлах с жёсткими правами
    umask 077
    tmp_priv=$(mktemp); tmp_pub=$(mktemp); tmp_psk=$(mktemp)
    wg genkey > "$tmp_priv"
    wg pubkey < "$tmp_priv" > "$tmp_pub"
    wg genpsk > "$tmp_psk"

    client_priv=$(cat "$tmp_priv")
    client_pub=$(cat "$tmp_pub")
    client_psk=$(cat "$tmp_psk")
    server_pub=$(cat "$SERVER_PUB_FILE")

    # 1) сохраняем в UCI (переживёт reboot)
    uci add network wireguard_${WG_IF} >/dev/null
    uci set network.@wireguard_${WG_IF}[-1].description="$name"
    uci set network.@wireguard_${WG_IF}[-1].public_key="$client_pub"
    uci set network.@wireguard_${WG_IF}[-1].preshared_key="$client_psk"
    uci add_list network.@wireguard_${WG_IF}[-1].allowed_ips="${client_ip}/32"
    uci set network.@wireguard_${WG_IF}[-1].persistent_keepalive='25'
    uci commit network
    ok "peer сохранён в UCI (переживёт перезагрузку)"

    # 2) применяем НА ЛЕТУ (без reload network -> существующие подключения не рвутся)
    wg set "$WG_IF" peer "$client_pub" \
        preshared-key "$tmp_psk" \
        allowed-ips "${client_ip}/32" \
        persistent-keepalive 25
    ok "peer добавлен в живой интерфейс $WG_IF (без разрыва других клиентов)"

    # 3) собираем конфиг клиента
    conf="$CLIENTS_DIR/${name}.conf"
    cat > "$conf" << CONFEOF
[Interface]
PrivateKey = $client_priv
Address = ${client_ip}/32
DNS = ${WG_SUBNET}.1

[Peer]
PublicKey = $server_pub
PresharedKey = $client_psk
Endpoint = ${ENDPOINT_HOST}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONFEOF
    chmod 600 "$conf"
    rm -f "$tmp_priv" "$tmp_pub" "$tmp_psk"
    ok "конфиг создан: $conf"

    echo ""
    printf "${C}=== Как перенести на устройство ===${N}\n"
    echo ""
    echo "Файлом (для Mac/ноутбуков) — выполните НА MAC:"
    echo "  scp -O root@192.168.8.1:$conf ~/Downloads/"
    echo "  затем импортируйте .conf в приложение WireGuard"
    echo ""
    echo "QR-кодом (для телефонов/планшетов) — выполните НА РОУТЕРЕ:"
    echo "  wg-client qr $name"
    echo ""
    warn "Конфиг содержит приватный ключ — не пересылайте его через чаты/почту."
    echo ""
    info "После переноса на устройство сотрите ключ с роутера:  wg-client purge $name"
}

### УДАЛЕНИЕ КЛИЕНТА ###
cmd_del() {
    name="$1"
    [ -n "$name" ] || err "укажите имя клиента: wg-client del <имя>"

    idx=$(find_peer_index "$name") || err "клиент '$name' не найден. Список: wg-client list"

    client_pub=$(uci get network.@wireguard_${WG_IF}[$idx].public_key 2>/dev/null || echo "")

    # 1) снимаем с живого интерфейса
    if [ -n "$client_pub" ]; then
        wg set "$WG_IF" peer "$client_pub" remove 2>/dev/null || true
        ok "peer снят с живого интерфейса"
    fi

    # 2) удаляем из UCI
    uci delete network.@wireguard_${WG_IF}[$idx]
    uci commit network
    ok "peer удалён из UCI"

    # 3) удаляем файл конфига
    conf="$CLIENTS_DIR/${name}.conf"
    if [ -f "$conf" ]; then
        rm -f "$conf"
        ok "конфиг удалён: $conf"
    fi

    info "клиент '$name' полностью удалён"
}

### СПИСОК КЛИЕНТОВ ###
cmd_list() {
    printf "${C}=== Клиенты WireGuard (%s) ===${N}\n\n" "$WG_IF"

    idx=0
    found=0
    while uci get network.@wireguard_${WG_IF}[$idx] >/dev/null 2>&1; do
        desc=$(uci get network.@wireguard_${WG_IF}[$idx].description 2>/dev/null || echo "(без имени)")
        cip=$(uci get network.@wireguard_${WG_IF}[$idx].allowed_ips 2>/dev/null || echo "?")
        cpub=$(uci get network.@wireguard_${WG_IF}[$idx].public_key 2>/dev/null || echo "")

        # статус из живого интерфейса: время последнего рукопожатия
        hs=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | grep "^$cpub" | awk '{print $2}')
        if [ -n "$hs" ] && [ "$hs" != "0" ]; then
            now=$(date +%s)
            ago=$((now - hs))
            if [ $ago -lt 180 ]; then
                status="${G}активен${N} (рукопожатие ${ago} сек назад)"
            else
                status="${Y}не в сети${N} (последний раз ${ago} сек назад)"
            fi
        else
            status="${Y}ни разу не подключался${N}"
        fi

        printf "  ${C}%-14s${N} %-18s " "$desc" "$cip"
        printf "$status\n"

        conf="$CLIENTS_DIR/${desc}.conf"
        [ -f "$conf" ] && printf "                 конфиг: %s\n" "$conf"

        found=1
        idx=$((idx + 1))
    done

    [ $found -eq 0 ] && warn "клиентов пока нет. Добавьте: wg-client add <имя>"
    echo ""
}

### QR-КОД ###
cmd_qr() {
    name="$1"
    [ -n "$name" ] || err "укажите имя клиента: wg-client qr <имя>"
    conf="$CLIENTS_DIR/${name}.conf"
    [ -f "$conf" ] || err "конфиг не найден: $conf (клиент существует? см. wg-client list)"

    command -v qrencode >/dev/null 2>&1 || err "qrencode не установлен. Поставьте: opkg install qrencode"

    info "сканируйте приложением WireGuard на телефоне/планшете:"
    echo ""
    qrencode -t ansiutf8 < "$conf"
}

### ПОКАЗАТЬ ПУТЬ / КОМАНДУ СКАЧИВАНИЯ ###
cmd_show() {
    name="$1"
    [ -n "$name" ] || err "укажите имя клиента: wg-client show <имя>"
    conf="$CLIENTS_DIR/${name}.conf"
    [ -f "$conf" ] || err "конфиг не найден: $conf"

    info "конфиг клиента '$name': $conf"
    echo ""
    echo "Скачать на Mac (выполните НА MAC):"
    echo "  scp -O root@192.168.8.1:$conf ~/Downloads/"
    echo ""
    echo "Параметры (без секретов):"
    grep -v "PrivateKey\|PresharedKey" "$conf" | sed 's/^/  /'
}

### УДАЛЕНИЕ ФАЙЛА КОНФИГА (клиент продолжает работать) ###
# Приватный ключ клиента по канонам WireGuard должен существовать ТОЛЬКО на самом
# клиенте. Серверу для работы нужен лишь публичный ключ (он в UCI). Поэтому после
# переноса конфига на устройство файл с роутера следует стереть — это убирает риск
# утечки приватных ключей всех клиентов при компрометации роутера.
# Если конфиг понадобится снова — пересоздайте клиента: wg-client del + wg-client add.
cmd_purge() {
    name="$1"
    [ -n "$name" ] || err "укажите имя клиента: wg-client purge <имя>"

    find_peer_index "$name" >/dev/null 2>&1 || err "клиент '$name' не найден. Список: wg-client list"

    conf="$CLIENTS_DIR/${name}.conf"
    if [ -f "$conf" ]; then
        rm -f "$conf"
        ok "конфиг стёрт с роутера: $conf"
        info "клиент '$name' продолжает работать (серверу нужен только публичный ключ)"
        warn "конфиг больше не восстановить. Если потребуется — пересоздайте: wg-client del $name && wg-client add $name"
    else
        info "конфига на роутере уже нет — клиент '$name' работает, приватный ключ только на устройстве"
    fi
}

### СПРАВКА ###
usage() {
    cat << 'HELPEOF'
wg-client — управление клиентами WireGuard-сервера на роутере

  wg-client add <имя>     создать клиента (ключи, IP, конфиг; без разрыва других)
  wg-client purge <имя>   стереть .conf с роутера (клиент продолжает работать)
  wg-client del <имя>     удалить клиента полностью
  wg-client list          список клиентов + статус подключения
  wg-client qr <имя>      QR-код конфига (для телефонов/планшетов)
  wg-client show <имя>    путь к конфигу + команда скачивания на Mac

Рекомендуемый порядок (безопасность):
  1. wg-client add macbook      создать клиента
  2. перенести .conf на устройство (scp или QR)
  3. wg-client purge macbook    стереть приватный ключ с роутера

Почему purge: приватный ключ клиента должен существовать только на самом клиенте.
Серверу для работы нужен лишь публичный ключ (хранится в UCI). Хранение всех
приватных ключей на роутере — лишний риск при его компрометации.

Что получает клиент:
  - доступ к домашней сети (192.168.8.0/24) из любой точки мира
  - интернет через дом: загран через Xray (обход блокировок), РФ напрямую
  - DNS через AdGuard роутера (блокировка рекламы работает и вне дома)
HELPEOF
}

### ГЛАВНОЕ ###
case "$1" in
    add)   check_env; cmd_add "$2" ;;
    purge) check_env; cmd_purge "$2" ;;
    del|remove|rm) check_env; cmd_del "$2" ;;
    list|ls) check_env; cmd_list ;;
    qr)    check_env; cmd_qr "$2" ;;
    show)  check_env; cmd_show "$2" ;;
    ""|-h|--help|help) usage ;;
    *)     err "неизвестная команда: $1 (см. wg-client --help)" ;;
esac
