# Полный откат Tailscale

Инструкция для полного удаления Tailscale и возврата роутера к состоянию без него —
после попытки, описанной в [отдельном документе](15-tailscale-exit-node-attempt.md).
Использовать, если Tailscale exit node создаст проблемы и нужно вернуться к
стабильному состоянию.

Плейсхолдеры: `<SERVER_IP>` — адрес VDS.

---

## Точка возврата (зафиксировано до установки Tailscale)

Эталонное состояние, к которому возвращаемся:

- `which tailscale` → не установлен;
- `opkg list-installed | grep -c tailscale` → 0;
- `uci show firewall | grep -ci tailscale` → 0;
- `ip link show | grep -c tailscale` → 0;
- `opkg list-installed | wc -l` → количество пакетов, зафиксированное до установки.

Если после отката все эти значения совпадают — откат полный.

---

## Шаги отката

### Шаг 1. Остановить и выключить Tailscale

```sh
tailscale down 2>/dev/null
/etc/init.d/tailscale stop 2>/dev/null
/etc/init.d/tailscale disable 2>/dev/null
```

### Шаг 2. Удалить пакеты Tailscale

```sh
opkg remove gl-sdk4-ui-tailscaleview 2>/dev/null
opkg remove gl-sdk4-tailscale 2>/dev/null
opkg remove tailscale 2>/dev/null
```

Примечание: `gl-sdk4-tailscale` и `gl-sdk4-ui-tailscaleview` — предустановленные
GL.iNet GUI-обёртки. Чтобы вернуть роутер в точности как был (с этими обёртками,
но без запущенного Tailscale) — их можно не удалять, а только выключить сервис
(Шаг 1). Полное удаление пакетов возвращает к чистому состоянию без Tailscale
вообще. Для полной чистоты — удалять всё.

### Шаг 3. Удалить конфиги и состояние Tailscale

```sh
rm -rf /etc/tailscale 2>/dev/null
rm -rf /var/lib/tailscale 2>/dev/null
rm -f /etc/config/tailscale 2>/dev/null
```

### Шаг 4. Снести интерфейс, если остался

```sh
ip link delete tailscale0 2>/dev/null
```

### Шаг 5. Убрать правила firewall Tailscale (если fw3 их оставил)

```sh
# проверить, есть ли зоны/правила tailscale
uci show firewall | grep -i tailscale
# если есть — удалить соответствующие секции (по номерам из вывода), например:
# uci delete firewall.@zone[N]   (где N — индекс зоны tailscale0)
# uci commit firewall
/etc/init.d/firewall restart
```

### Шаг 6. Убедиться, что основной tproxy/VPN цел

```sh
/etc/init.d/xray-tproxy restart
sleep 14
iptables -t mangle -S PREROUTING | grep XRAY    # ожидается: -i br-lan -j XRAY
ps w | grep '[x]ray' | grep client.json && echo "Xray OK"
```

### Шаг 7. Проверка отката (сверить с точкой возврата)

```sh
which tailscale 2>/dev/null || echo "tailscale удалён"
opkg list-installed | grep -c tailscale     # ожидается 0
uci show firewall | grep -ci tailscale      # ожидается 0
ip link show | grep -c tailscale            # ожидается 0
opkg list-installed | wc -l                 # сверить с зафиксированным числом пакетов
```

Если все значения совпали с точкой возврата — откат полный, Tailscale нет.

Проверить интернет из рабочей домашней сети. Всё должно открываться без проблем.

---

## Что откат не трогает (остаётся рабочим)

Откат Tailscale не затрагивает основной стек — он остаётся полностью рабочим:

- Xray + tproxy (VPN-туннель) с исправлением `-i br-lan`;
- AdGuard Home (DNS + блокировка рекламы);
- хук `firewall.user` (переприменение tproxy при reload fw3);
- скрипты-инструменты (`xray-route`, `xray-link`, `xray-kernel`, `xray-geoupdate`);
- отключённые лишние сервисы.

Откат убирает только Tailscale.

---

## Важно про TIME_WAIT

Если во время работы с Tailscale накопился TIME_WAIT (от множественных
рестартов), очистить вручную:

```sh
conntrack -D -d <SERVER_IP> -p tcp --state TIME_WAIT
```

Это освободит порты к серверу. При обычной эксплуатации не требуется — очистка
встроена в `tproxy-apply.sh`.
