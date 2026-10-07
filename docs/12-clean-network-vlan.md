# Чистая сеть без туннелирования (VLAN): проводная и Wi-Fi

Как поднять рядом с основной домашней сетью вторую — **чистую**, которая идёт напрямую
через провайдера, минуя туннель. Нужна для диагностики (проверить, работает ли ссылка
сама по себе), для сервисов, которые требуют прямого подключения, и как аварийный доступ,
когда туннель недоступен.

Реализация: GL-MT5000 (OpenWrt, коммутатор swconfig) + MikroTik hAP ac² как точка доступа.
Принцип универсален, конкретные команды — под это железо.

Документ предполагает, что MikroTik уже настроен точкой доступа. Если это ещё не
сделано — см. [«MikroTik как точка доступа»](03-mikrotik-access-point.md).

Плейсхолдеры: `<HOME_NET>` — домашняя подсеть (в примере 192.168.8.0/24),
`<CLEAN_NET>` — чистая (в примере 192.168.20.0/24).

---

## 1. Идея

Ключевой момент: tproxy в этой сборке перехватывает **только явно перечисленные интерфейсы**
(`-i br-lan` и `-i wg0`). Значит любой новый интерфейс автоматически остаётся вне перехвата
и его трафик идёт напрямую. Поэтому чистую сеть достаточно просто создать — правила tproxy
менять не нужно вообще.

```
          ┌─ VLAN 1  (untagged) → br-lan   → tproxy → Xray → VPN
кабель ───┤
(ether1)  └─ VLAN 20 (tagged)   → eth0.20  → напрямую в WAN
```

На MikroTik два SSID: обычный отдаёт кадры без тега (попадают в VLAN 1),
чистый — с тегом 20.

---

## 2. Часть A. MT5000: проводная чистая сеть (LAN2)

Начинать лучше с проводной: свободный порт трогать безопасно, и по нему потом
можно попасть на роутер, если что-то сломается.

### Разведка портов

```sh
swconfig dev switch0 show | grep -E "^Port|link:"     # какой порт занят
swconfig dev switch0 show | grep -E "^VLAN|ports:"    # текущая разметка
```

В примере: `Port 0` — кабель на точку доступа, `Port 1` (LAN2) свободен, `Port 17` — CPU.

### Настройка

```sh
# порт 1 (LAN2) убираем из домашней VLAN 1
uci set network.vlan_lan.ports='0 17t'

# создаём VLAN 20 на порту 1 (untagged) + CPU (tagged)
uci set network.vlan_clean=switch_vlan
uci set network.vlan_clean.device='switch0'
uci set network.vlan_clean.vlan='20'
uci set network.vlan_clean.ports='1 17t'

# интерфейс чистой сети
uci set network.clean=interface
uci set network.clean.device='eth0.20'
uci set network.clean.proto='static'
uci set network.clean.ipaddr='192.168.20.1'
uci set network.clean.netmask='255.255.255.0'

# DHCP
uci set dhcp.clean=dhcp
uci set dhcp.clean.interface='clean'
uci set dhcp.clean.start='100'
uci set dhcp.clean.limit='50'
uci set dhcp.clean.leasetime='12h'

# firewall: интернет — да, домашняя сеть — нет, доступ к роутеру — да
uci add firewall zone
uci set firewall.@zone[-1].name='clean'
uci set firewall.@zone[-1].network='clean'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='clean'
uci set firewall.@forwarding[-1].dest='wan'

uci changes          # проверить перед применением
uci commit network; uci commit dhcp; uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall restart
```

`input='ACCEPT'` оставляет доступ к самому роутеру из чистой сети — это и есть
аварийный путь. `forward='REJECT'` + разрешение только `clean → wan` изолирует
чистую сеть от домашней.

### Проверка

```sh
ip addr show eth0.20 | grep inet                  # 192.168.20.1
iptables -t mangle -S PREROUTING | grep XRAY      # только br-lan и wg0 — eth0.20 не перехватывается
```

Воткнуть компьютер в LAN2, выключить Wi-Fi, проверить: адрес `192.168.20.x`,
а внешний IP (например через api.ipify.org) — домашний, не адрес VPN-сервера.

---

## 3. Часть B. MT5000: пропустить VLAN 20 на порт точки доступа

Чтобы чистая сеть дошла до Wi-Fi, порт с точкой доступа должен нести обе VLAN:
домашнюю untagged и чистую tagged.

### Главная грабля: pvid

Драйвер RTL8366UB при добавлении порта в VLAN **самовольно переставляет `pvid` порта
на эту VLAN — даже если порт добавлен тегированным**. В результате весь нетегированный
трафик с точки доступа уходит в чистую VLAN, а домашняя сеть исчезает.

Симптом: после применения устройства подключаются к Wi-Fi, но интернета нет и адреса
домашней сети не выдаются.

**Лечится явной фиксацией pvid:**

```sh
uci set network.vlan_clean.ports='1 0t 17t'      # порт 0 добавлен тегированным

uci add network switch_port                       # и сразу фиксируем его pvid
uci set network.@switch_port[-1].device='switch0'
uci set network.@switch_port[-1].port='0'
uci set network.@switch_port[-1].pvid='1'

uci commit network
reboot                # именно reboot: reload коммутатор применяет неполно
```

### Проверка после перезагрузки

```sh
swconfig dev switch0 port 0 show | grep pvid      # должно быть 1
swconfig dev switch0 port 1 show | grep pvid      # должно быть 20
swconfig dev switch0 show | grep -E "^VLAN|ports:"
ip addr show br-lan | grep inet
ip addr show eth0.20 | grep inet
```

Если `pvid` порта 0 равен 20 — фиксация не применилась, домашняя сеть ляжет.

---

## 4. Часть C. MikroTik: второй SSID с тегом VLAN 20

Приятная особенность RouterOS: беспроводной интерфейс **умеет тегировать сам**
(`vlan-mode=use-tag`). Поэтому мост трогать не нужно — достаточно виртуальной точки доступа.

```sh
/interface wireless security-profiles add name=CleanNet mode=dynamic-keys \
    authentication-types=wpa2-psk unicast-ciphers=aes-ccm group-ciphers=aes-ccm \
    wpa2-pre-shared-key="<ПАРОЛЬ>"

/interface wireless add name=clean-ap master-interface="5GHz" ssid="<ИМЯ_СЕТИ>" \
    mode=ap-bridge security-profile=CleanNet vlan-mode=use-tag vlan-id=20 disabled=no

/interface bridge port add bridge=bridge interface=clean-ap
```

Кавычки вокруг `"5GHz"` обязательны — имена, начинающиеся с цифры, ломают парсер RouterOS.

### Проверка

Подключиться к новой сети: адрес `192.168.20.x`, внешний IP — домашний.
Обычная сеть при этом должна продолжать работать через VPN.

Откат:

```sh
/interface bridge port remove [find interface=clean-ap]
/interface wireless remove [find name=clean-ap]
/interface wireless security-profiles remove [find name=CleanNet]
```

---

## 5. Часть D (опционально). Строгая изоляция: vlan-filtering

Без `vlan-filtering` мост не понимает теги: кадры VLAN 20 расходятся и на другие порты.
Обычные клиенты их отбрасывают, но устройство внутри сети, настроив у себя VLAN-интерфейс
с тегом 20, увидело бы этот трафик. Для строгой изоляции включается фильтрация.

### Safe Mode здесь не работает

Включение `vlan-filtering` само по себе кратко рвёт связь (мост переинициализируется),
а Safe Mode на любой обрыв откатывает изменения. Получается замкнутый круг.

**Рабочий приём — таймер автоотката:**

```sh
# страховка: через 3 минуты фильтрация выключится сама, если её не подтвердить
/system scheduler add name=vlan-rollback interval=3m \
  on-event="/interface bridge set bridge vlan-filtering=no; /system scheduler remove [find name=vlan-rollback]"
/system scheduler print          # убедиться, что запись создалась

# разметка
/interface bridge vlan add bridge=bridge vlan-ids=1 \
    untagged=bridge,ether1,ether2,ether3,ether4,ether5,"2GHz","5GHz"
/interface bridge vlan add bridge=bridge vlan-ids=20 tagged=ether1,clean-ap
/interface bridge vlan print detail       # проверить до включения

# включение
/interface bridge set bridge vlan-filtering=yes
```

Связь моргнёт. Переподключиться, проверить обе сети — и **успеть за 3 минуты** снять таймер:

```sh
/system scheduler remove [find name=vlan-rollback]
```

Не успел или сломалось — устройство само вернёт `vlan-filtering=no`.

Подключаться на время этой операции лучше **кабелем в LAN-порт точки доступа**:
при ошибке в разметке Wi-Fi отвалится первым, а проводной порт останется.

### Про потерю hw-offload

После включения фильтрации флаг `H` (аппаратное ускорение) исчезает у всех портов моста —
чипсет IPQ4019 не умеет обрабатывать VLAN-фильтрацию в железе.

**Практического влияния в роли точки доступа нет:** беспроводной трафик никогда не
ускоряется аппаратно, offload работал бы только для передачи ethernet↔ethernet.
Замеры после включения: Замеры скорости показали те же результаты, что и до изменений. Под нагрузкой — три видео в 4K, загрузка процессора ~1% — то же, что и до.

---

## 6. Отдельный DNS для чистой сети

Изначально чистая сеть использовала общий с домашней резолвер (dnsmasq → AdGuard).
При отказе AdGuard она падала вместе с домашней и переставала выполнять роль
диагностического пути.

Клиентам чистой сети раздаются публичные резолверы напрямую:

```sh
uci add_list dhcp.clean.dhcp_option='6,1.1.1.1,9.9.9.9'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Побочный эффект: в чистой сети нет фильтрации рекламы. Для диагностики это скорее плюс —
видно «сырой» интернет.

---

## 7. Что получилось

| Путь          | Куда идёт трафик | Назначение                 |
| ------------- | ---------------- | -------------------------- |
| обычный SSID  | через VPN        | повседневная работа        |
| чистый SSID   | напрямую         | диагностика, прямой доступ |
| кабель в LAN2 | напрямую         | аварийный доступ к роутеру |

Переключение между VPN и чистым каналом — просто выбор сети на устройстве.

---

## 8. Порядок действий и страховки (сводка)

1. Полный бэкап обоих устройств до начала.
2. Проводная чистая сеть на свободном порту — безопасно, ничего не ломает.
3. Тегированная VLAN на порт точки доступа + **обязательная фиксация pvid** + `reboot`.
4. Второй SSID на точке доступа с `vlan-mode=use-tag`.
5. (Опционально) `vlan-filtering` с таймером автоотката.

На каждом шаге держать альтернативный путь к устройству: проводной порт для роутера,
подключение по MAC (Winbox) для точки доступа.
