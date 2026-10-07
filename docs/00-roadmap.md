# Обзор стека и оглавление документации

## Что за стек

Два устройства:

- **GL-MT5000 (OpenWrt)** — основной роутер: прозрачный VPN-шлюз для всей домашней
  сети, одновременно WireGuard-сервер для доступа извне.
- **MikroTik** — точка доступа Wi-Fi, подключённая к GL-MT5000 и раздающая ту же
  сеть; сам не занимается маршрутизацией, DHCP и NAT — это делает основной роутер.

Компоненты на GL-MT5000:

- **Xray (VLESS + Reality + Vision)** — туннель до VDS;
- **tproxy** — прозрачный перехват трафика (раздельная маршрутизация по geoip:
  часть через Xray, часть напрямую);
- **AdGuard Home** — локальный DNS-резолвер с шифрованным upstream + блокировка рекламы;
- **WireGuard-сервер** — удалённый доступ к домашней сети.

---

## Оглавление

### Подготовка и доступ

- [01. SSH: ключи, алиасы, бэкап](01-ssh-keys-and-connections.md)
- [02. Перевод роутера с CN на Global](02-router-cn-to-global.md)
- [03. MikroTik как точка доступа](03-mikrotik-access-point.md)

### VDS и туннель

- [04. Базовый хардненинг VDS](04-vds-hardening.md)
- [05. Xray Reality + tproxy: установка](05-xray-reality-tproxy.md)

### Инструменты

- [06. Обзор скриптов и разбор TIME_WAIT](06-scripts-overview-and-time-wait.md)
- [07. xray-route: исключения роутинга](07-xray-route.md)
- [08. xray-link: смена сервера по ссылке](08-xray-link.md)
- [09. xray-kernel: смена версии ядра Xray](09-xray-kernel.md)
- [10. xray-geoupdate: обновление geodata](10-xray-geoupdate.md)

### DNS и сеть

- [11. DNS/AdGuard + автозапуск](11-dns-adguard-autostart.md)
- [12. Чистая сеть без туннелирования (VLAN)](12-clean-network-vlan.md)

### Диагностика

- [13. Диагностика: «VPN перестал работать»](13-vpn-tunnel-diagnostics.md)
- [14. DNS: диагностика сбоя и резолв через туннель](14-dns-diagnostics-and-tunnel.md)
- [15. Собственный рекурсивный DNS-резолвер](15-own-recursive-resolver.md)

### Удалённый доступ

- [16. Tailscale exit node: попытка и причина отказа](16-tailscale-exit-node-attempt.md)
- [17. Полный откат Tailscale](17-tailscale-rollback.md)
- [18. WireGuard-сервер](18-wireguard-server.md)
- [19. Роутер как WireGuard-клиент VPS](19-router-as-wg-client.md)

### Гигиена

- [20. Отключение лишних сервисов на роутере](20-disabling-unused-services.md)

---

## Статус

Описанная конфигурация полностью рабочая и проверена на практике — от установки
туннеля и разделения трафика по geoip до диагностики сбоев и резервных путей
удалённого доступа.
