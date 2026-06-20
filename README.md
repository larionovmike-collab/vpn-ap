# Raspberry Pi WiFi AP через SSH SOCKS

Интерактивный установщик превращает Raspberry Pi с проводным управлением в WiFi-точку доступа. Весь IPv4 TCP-трафик клиентов прозрачно передаётся через классический SSH dynamic SOCKS на VPS. UDP блокируется fail-closed, а DNS отправляется по DoH через тот же SOCKS-туннель.

```text
WiFi-клиент
  -> Raspberry Pi wlan0 (hostapd + dnsmasq)
  -> iptables REDIRECT
  -> redsocks
  -> SSH SOCKS5 (ssh -D)
  -> VPS sshd
  -> Internet
```

Проект не использует WireGuard, OpenVPN, SSH TUN или собственный транспорт. Default route Raspberry Pi и VPS не заменяется. Управляющий SSH Raspberry продолжает идти напрямую через её проводной интерфейс.

## Требования

### Raspberry Pi

- проверенная модель: Raspberry Pi 3 Model B+;
- встроенный WiFi-интерфейс `wlan0` с поддержкой AP mode;
- проводной интерфейс `eth0` для управления и основного доступа в Интернет;
- стабильный блок питания не менее 5 В / 2,5 А;
- не менее 1 ГБ свободного места на системном разделе.

Установщик рассчитан на:

- Raspberry Pi OS Lite или Raspberry Pi OS с рабочим столом на базе Debian 13 (Trixie);
- Debian 13 для Raspberry Pi;
- 32- или 64-битную ARM-систему;
- `systemd`, пакетный менеджер `apt` и стандартное Linux-ядро с Netfilter/iptables.

Рабочая конфигурация была проверена на Raspberry Pi 3 B+ с чистой Debian 13.5. Другие Debian-подобные системы могут работать, но автоматически не считаются поддерживаемыми.

Во время установки должны выполняться следующие условия:

- Raspberry подключена к роутеру кабелем через `eth0`;
- default route и текущий управляющий SSH-доступ используют не `wlan0`;
- Raspberry имеет доступ к Debian-репозиториям и может устанавливать пакеты;
- исходящие TCP-соединения к порту 22 VPS разрешены;
- запуск выполняется от `root` либо через `sudo` в интерактивном терминале.

Docker, Go, WireGuard, OpenVPN и предварительная установка `hostapd` не требуются.

### VPS

- публичный IPv4-адрес и доступ в Интернет;
- Linux с OpenSSH Server;
- SSH на TCP-порту 22;
- `AllowTcpForwarding yes`;
- парольная SSH-аутентификация доступна на время первоначальной установки;
- учётная запись может записывать собственный файл `~/.ssh/authorized_keys`.

Установщик не требует root-доступа к VPS, если обычному пользователю разрешён TCP forwarding.

### Подготовка чистой системы

1. Запишите свежий образ Raspberry Pi OS Lite на карту памяти.
2. Включите SSH и создайте пользователя с правом `sudo` через Raspberry Pi Imager.
3. Подключите Raspberry к роутеру кабелем.
4. Загрузите систему и убедитесь, что SSH и доступ в Интернет работают через `eth0`.
5. Запустите команду быстрой установки. Вручную устанавливать пакеты или настраивать `wlan0` не нужно.

## Быстрая установка

```bash
curl -fsSL https://raw.githubusercontent.com/larionovmike-collab/vpn-ap/refs/heads/main/install.sh | sudo bash
```

Скрипт последовательно запросит:

1. имя WiFi-точки доступа;
2. пароль WiFi;
3. IPv4-адрес VPS;
4. SSH-логин VPS;
5. SSH-пароль VPS.

Перед изменениями создаётся резервная копия в `/var/backups/vpn-ap-installer/`. Скрипт автоматически выбирает свободную `/24`-подсеть, не пересекающуюся с маршрутами Raspberry и VPS, закрепляет SSH host key после подтверждения отпечатка и проверяет каждый слой до включения прозрачного redirect.

## Что изменяется на VPS

Установщик не меняет firewall, NAT, маршруты, default route или конфигурацию `sshd`. В `~/.ssh/authorized_keys` указанного пользователя добавляется только отдельный Ed25519-ключ с ограничениями `restrict,port-forwarding` и запрещённой shell-командой. Перед этим создаётся копия `~/.vpn-ap-backups/authorized_keys.<дата>`.

## Проверка

После установки подключитесь к созданной WiFi-сети и проверьте:

```text
https://1.1.1.1/cdn-cgi/trace
https://browserleaks.com/ip
```

Внешний IPv4 должен принадлежать VPS, IPv6 должен отсутствовать. Из-за намеренной блокировки UDP приложения используют TCP вместо QUIC, поэтому начало соединения иногда занимает чуть больше времени.

Состояние сервисов на Raspberry:

```bash
systemctl status vpn-ap-socks vpn-ap-redsocks vpn-ap-transparent
systemctl status vpn-ap-watchdog.timer dnscrypt-proxy hostapd dnsmasq
```

## Откат

```bash
curl -fsSL https://raw.githubusercontent.com/larionovmike-collab/vpn-ap/refs/heads/main/rollback.sh | sudo bash
```

Откат восстанавливает файлы из последней резервной копии, удаляет только цепочки `VPN_AP_REDSOCKS`/`VPN_AP_FAIL_CLOSED`/`VPN_AP6_FAIL_CLOSED` и при необходимости удаляет с VPS только добавленный установщиком ключ. Установленные пакеты намеренно не удаляются.

## Ограничения

- Туннелируется только IPv4 TCP.
- UDP и IPv6-доступ клиентов в Интернет отсутствуют.
- Производительность зависит от CPU Raspberry Pi, качества WiFi, SSH и VPS.
- Перед подтверждением SSH fingerprint сверьте его с консолью или панелью VPS-провайдера.
