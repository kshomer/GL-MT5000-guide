# Собственный рекурсивный DNS-резолвер на VPN-сервере

Как поднять на своём VPS резолвер, который сам обходит цепочку от корневых серверов, и
направить в него DNS-запросы домашней сети через VPN-туннель. Результат: полной картины
запрашиваемых доменов не собирает никто — ни провайдер, ни публичные DNS-сервисы.

Схема реализована на связке «роутер с Xray в tproxy-режиме» + «VPS с Xray-сервером в Docker».

Плейсхолдеры: `<SERVER_IP>` — адрес VPS, `<DOCKER_NET>` — имя docker-сети Xray,
`<GW>` — адрес docker-шлюза (обычно 172.18.0.1), `<router>` — алиас роутера в ssh-конфиге.

---

## 1. Зачем это нужно

Обычный DoH-резолвер (Cloudflare, Google, Яндекс) видит **все** запрашиваемые домены.
Даже если запросы идут через VPN-туннель, провайдер их не читает — но сам DoH-сервис
получает полный список.

Собственная рекурсия убирает этого посредника. Резолвер сам спрашивает корневые серверы
(«кто отвечает за зону .com?»), затем серверы зоны, затем авторитативный сервер домена.
Каждый участник видит только свой кусок цепочки, полной картины нет ни у кого.

Дополнительный эффект: нет зависимости от известных публичных DoH-сервисов.

### Сравнение режимов

| Upstream в AdGuard                       | Путь запроса     | Кто видит домены                                 |
| ---------------------------------------- | ---------------- | ------------------------------------------------ |
| публичный DoH напрямую                   | через провайдера | провайдер (факт обращения) + DoH-сервис (домены) |
| DoH зоны `.ru` напрямую                  | через провайдера | этот сервис                                      |
| локальный порт → туннель → свой резолвер | через VPN        | **никто**                                        |

---

## 2. Архитектура

```
клиент → AdGuard на роутере
            ├─ .ru       → DoH зоны `.ru` напрямую (геолокация CDN + запас на случай падения туннеля)
            └─ остальное → 127.0.0.1:5354
                              ↓ (Xray-инбаунд dns-in, правило → proxy)
                           VPN-туннель
                              ↓
                        Xray на VPS → правило порт 53 → outbound to-unbound
                              ↓
                        unbound на VPS → корневые серверы → зона → авторитативный сервер
```

---

## 3. Часть A. Резолвер на VPS

### Установка

```sh
apt update && apt install -y unbound
unbound -V | head -2
```

После установки unbound уже слушает `127.0.0.1:53` и работает как рекурсивный резолвер —
без пересылки к кому-либо.

### Проверка, что это рекурсия, а не пересылка

```sh
dig @127.0.0.1 github.com +short           # резолвит
dig @127.0.0.1 cloudflare.com +dnssec | grep "^;; flags"   # должен быть флаг ad (DNSSEC проверен)
dig @127.0.0.1 wikipedia.org | grep "Query time"           # первый запрос ~200-300 мс
dig @127.0.0.1 wikipedia.org | grep "Query time"           # повторный ~1 мс (кэш)
grep -r "forward" /etc/unbound/ | grep -v "#"              # пересылки быть НЕ должно
```

Медленный первый запрос — признак рекурсии: резолвер проходит цепочку. Дальше работает кэш.

### Настройка доступа для контейнера Xray

Узнать адрес docker-шлюза:

```sh
docker network inspect <DOCKER_NET> --format '{{range .IPAM.Config}}{{.Gateway}} {{.Subnet}}{{end}}'
```

Создать `/etc/unbound/unbound.conf.d/xray-tunnel.conf`:

```yaml
server:
    interface: 127.0.0.1
    interface: <GW>

    access-control: 127.0.0.0/8 allow
    access-control: 172.18.0.0/16 allow

    qname-minimisation: yes
    hide-identity: yes
    hide-version: yes
    cache-min-ttl: 60
    prefetch: yes
```

Применить и проверить:

```sh
unbound-checkconf && systemctl restart unbound
ss -tulnp | grep unbound
```

⚠️ **Не добавлять `access-control: 0.0.0.0/0 refuse`** — эта строка перекрывает разрешения
ниже и приводит к отказу `REFUSED` даже для разрешённых подсетей. Без неё unbound по
умолчанию отказывает всем, кого не разрешили явно — защита сохраняется.

`qname-minimisation` отправляет каждому серверу в цепочке минимум информации: корневым —
только зону верхнего уровня, а не полное имя. Прямо в тему приватности.

### Firewall

Политика «deny incoming» блокирует и трафик с docker-интерфейса. Разрешить точечно:

```sh
ufw allow from 172.18.0.0/16 to <GW> port 53 proto udp comment 'unbound for xray container'
ufw allow from 172.18.0.0/16 to <GW> port 53 proto tcp comment 'unbound for xray container'
```

**Обязательная проверка — порт 53 не должен быть доступен из интернета:**

```sh
ss -tulnp | grep ":53 " | grep -vE "127.0.0|::1|172.18" || echo "публично НЕ слушает"
```

Открытый рекурсивный резолвер используют для DDoS-атак с усилением, и хостер за это
выписывает предупреждения. В этой схеме порт слушается только на внутренних адресах.

### Проверка из контейнера

```sh
docker run --rm --network <DOCKER_NET> alpine sh -c \
  'apk add --no-cache bind-tools >/dev/null 2>&1 && dig @<GW> github.com +short'
```

Вернулся адрес — резолвер доступен оттуда, откуда к нему будет обращаться Xray.

---

## 4. Часть B. Xray на VPS — направить DNS в резолвер

### Главная ловушка: блокировка приватных адресов

Свежие версии Xray применяют встроенное правило `defaultBlockPrivateRule`: исходящие
соединения на приватные диапазоны (включая `172.16.0.0/12`, где живут docker-сети)
**блокируются** для inbound-протоколов vless, vmess, trojan, hysteria, wireguard.

В логах это выглядит так:

```
proxy/freedom: blocked target: udp:172.18.0.1:53, blackholing connection for 49s
```

Обходится параметром `finalRules` в настройках freedom-outbound — точечным разрешением
для конкретного адреса и порта. Параметр `domainStrategy` на это не влияет.

Источник: обсуждение XTLS/Xray-core #6157, документация — раздел FinalRuleObject
на xtls.github.io в описании freedom.

### Правка конфига

```sh
cd /opt/<xray-dir>
cp config/config.json config/config.json.before-unbound

jq '
  .outbounds += [{
    "tag": "to-unbound",
    "protocol": "freedom",
    "settings": {
      "redirect": "<GW>:53",
      "finalRules": [
        {
          "action": "allow",
          "network": "tcp,udp",
          "port": "53",
          "ip": ["<GW>"]
        }
      ]
    }
  }]
  | .routing.rules = [{
      "type": "field",
      "port": 53,
      "network": "udp,tcp",
      "outboundTag": "to-unbound"
    }]
' config/config.json > /tmp/config-unbound.json

jq empty /tmp/config-unbound.json && echo "JSON валиден"
cp /tmp/config-unbound.json config/config.json
docker restart <xray-container>
```

Правило ловит любой трафик на порт 53, пришедший из туннеля, и отправляет его в резолвер.
Разрешение узкое: только порт 53, только один адрес — остальные приватные диапазоны
остаются заблокированными.

---

## 5. Часть C. Роутер — отправить DNS в туннель

### Инбаунд в Xray на роутере

```sh
cd /opt/xray/config
cp client.json client.json.before-dns-tunnel

jq '
  .inbounds += [{
    "tag": "dns-in",
    "protocol": "dokodemo-door",
    "listen": "127.0.0.1",
    "port": 5354,
    "settings": { "address": "1.1.1.1", "port": 53, "network": "tcp,udp" }
  }]
  | .routing.rules = ([{
      "type": "field",
      "inboundTag": ["dns-in"],
      "outboundTag": "proxy"
    }] + .routing.rules)
' client.json > /tmp/client-dnstunnel.json

jq empty /tmp/client-dnstunnel.json && cp /tmp/client-dnstunnel.json client.json
/etc/init.d/xray-tproxy restart
```

Адрес `1.1.1.1` тут — формальная цель: сервер всё равно перехватит запрос по порту 53 и
отправит в свой резолвер. Правило маршрутизации ставится **первым**, чтобы сработать
раньше разделения по geoip.

⚠️ **Порт выбирать свободный.** 5353 занят avahi-daemon (mDNS, нужен для AirDrop) — Xray
на нём не поднимется, уйдёт в crash loop.

### Проверка

```sh
netstat -tulnp | grep 5354                     # Xray слушает
dig @127.0.0.1 -p 5354 github.com +short       # резолв через туннель
```

Первый запрос может дать таймаут, пока цепочка прогревается — повторить.

⚠️ Диагностические грабли:

- `xray -test` показывает «Configuration OK» даже когда порт занят — проверяет только
  синтаксис. Ошибки запуска ищутся в `logread`, не в файле лога Xray;
- busybox `nslookup` не понимает `-port=`; использовать `dig @127.0.0.1 -p <порт>`.

### Подтверждение с сервера

```sh
unbound-control stats_noreset | grep total.num.queries=
```

Счётчик растёт — запросы дошли до резолвера, цепочка замкнулась.

---

## 6. Переключение между режимами

Меняется только строка upstream в конфиге AdGuard на роутере. Всё остальное
(инбаунд, правила, резолвер) остаётся на месте и ждёт.

⚠️ **Команды переключения ищут в конфиге строку с публичным DoH, поэтому работают
только из Режима 1.** Если сейчас включён режим 2 или 3, сначала вернуться в исходный
(команда ниже), затем применять нужный. ⚠️

⚠️ **Правило простое: любое переключение начинается с возврата в Режим 1.** ⚠️

```
Режим 1 (исходный) ──> Режим 2 (Яндекс)
        ↑
        └────────────── Режим 3 (свой резолвер)
```

### Режим 1 — публичный DoH напрямую (исходный)

```yaml
upstream_dns:
  - "[/ru/]https://common.dot.dns.yandex.net/dns-query"
  - https://cloudflare-dns.com/dns-query
  - https://dns.quad9.net/dns-query
```

Обычный режим. Зависит от доступности внешних DoH.

Отдельной команды нет — это возврат к сохранённому конфигу:

```sh
cp /etc/AdGuardHome/config.yaml.before-tunnel /etc/AdGuardHome/config.yaml
/etc/init.d/adguardhome restart
```

### Режим 2 — один резолвер (аварийный)

```yaml
upstream_dns:
  - "[/ru/]https://common.dot.dns.yandex.net/dns-query"
  - https://common.dot.dns.yandex.net/dns-query
```

При недоступности внешних DoH. Работает сразу, но один сервис видит все запросы.

Командой:

```sh
sed -i "s|    - https://cloudflare-dns.com/dns-query|    - https://common.dot.dns.yandex.net/dns-query|" /etc/AdGuardHome/config.yaml
sed -i "\|    - https://dns.quad9.net/dns-query|d" /etc/AdGuardHome/config.yaml
/etc/init.d/adguardhome restart
```

### Режим 3 — свой резолвер через туннель

```yaml
upstream_dns:
  - "[/ru/]https://common.dot.dns.yandex.net/dns-query"
  - 127.0.0.1:5354
```

Максимальная приватность, независимость от внешних резолверов.

Командой:

```sh
sed -i 's|^    - https://cloudflare-dns.com/dns-query$|    - 127.0.0.1:5354|' /etc/AdGuardHome/config.yaml
sed -i '\|^    - https://dns.quad9.net/dns-query$|d' /etc/AdGuardHome/config.yaml
/etc/init.d/adguardhome restart
```

### Проверка после любого переключения

```sh
sleep 15
grep -A4 "upstream_dns:" /etc/AdGuardHome/config.yaml    # что реально применилось
nslookup github.com 127.0.0.1 | tail -3                  # внешний домен
nslookup ya.ru 127.0.0.1 | tail -3                       # домен зоны .ru
```

Первая команда важна: показывает фактическое состояние конфига, а не предполагаемое.

---

## 7. Что держать в голове

**Зона `.ru` всегда идёт напрямую.** Причина — геолокация: запрос
из-за границы может вернуть неоптимальный адрес CDN. Побочная польза — при падении
туннеля `.ru` продолжает резолвиться.

**Режим 3 зависит от туннеля.** Упадёт Xray — внешние имена перестанут резолвиться.
Осознанный размен: раньше зависели от доступности чужого DoH, теперь от своего туннеля.

**Первый запрос к новому домену медленнее.** Рекурсия проходит цепочку от корня. Дальше
работает кэш, разницы не видно.

**Резолвер требует обслуживания.** Обновления пакета, проверка что не открылся наружу
после изменений в firewall.

**Проверять доступность DoH нужно с рабочей машины в сети, идущей мимо туннеля.** Проверка
с роутера через curl недостоверна, а из сети с VPN покажет путь через сервер, а не через
провайдера.
