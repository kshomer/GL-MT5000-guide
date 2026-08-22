#!/bin/sh
# tproxy-flush.sh — мгновенный откат всех tproxy-правил и маршрутов.
# Возвращает роутер в исходное состояние (без перехвата трафика).
# Безопасен для повторного запуска: ошибки "правила нет" игнорируются.

# 1. Удаляем цепочку XRAY из таблицы mangle (все формы джампа: старая, br-lan, wg0)
iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null
iptables -t mangle -D PREROUTING -i br-lan -j XRAY 2>/dev/null
iptables -t mangle -D PREROUTING -i wg0 -j XRAY 2>/dev/null
iptables -t mangle -F XRAY 2>/dev/null
iptables -t mangle -X XRAY 2>/dev/null

# 2. Удаляем цепочку XRAY_SELF (перехват трафика самого роутера, если ставили)
iptables -t mangle -D OUTPUT -j XRAY_SELF 2>/dev/null
iptables -t mangle -F XRAY_SELF 2>/dev/null
iptables -t mangle -X XRAY_SELF 2>/dev/null

# 3. Снимаем QUIC-блок (раньше оставался висеть после остановки — исправлено)
iptables -t raw -D PREROUTING -i br-lan -p udp --dport 443 -j DROP 2>/dev/null

# 4. Удаляем policy-routing: правило по метке и локальную таблицу 100
ip rule del fwmark 1 table 100 2>/dev/null
ip route flush table 100 2>/dev/null

echo "[tproxy-flush] Все tproxy-правила и маршруты сброшены. Трафик идёт напрямую."
