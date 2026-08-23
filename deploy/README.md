# Развёртывание через общий TCP/443

Автоматический установщик сохраняет существующий nginx/Caddy и добавляет
только L4-маршрут выделенного FakeTLS SNI.

```text
Telegram ClientHello
        │
        ▼
nginx stream / Caddy layer4 :443
        │
        ├── FakeTLS SNI ── raw TCP + PROXY v2 ── tupoproxy :18443
        └── другие SNI ────────────────────────── существующие сайты
```

FakeTLS-ветка повторяет прямую HMAC-only логику: правильный credential получает
TLS 1.3-похожий ServerHello, неправильный credential закрывается без
сертификата и fallback. Reverse proxy не завершает TLS на этой ветке.

## Требования

- origin-домен имеет одну прямую A-запись на IPv4 VPS;
- отдельный FakeTLS-домен существует, но может иметь другой DNS-адрес;
- edge владеет публичным TCP/443;
- nginx содержит `stream_ssl_preread_module` либо Caddy содержит caddy-l4;
- изменяемый Docker config находится в постоянном bind/volume mount.

Для стандартного Docker Caddy установщик добавляет caddy-l4 штатной командой
`caddy add-package --keep-backup`. Предыдущие модули проверяются после сборки,
а исходный бинарник сохраняется для отката.

Read-only Docker mount поддерживается: интегратор определяет его host source и
изменяет существующий файл на месте. Режим mount, контейнер и соседние файлы не
пересоздаются.

## Сетевые границы

- публичный edge слушает TCP/443;
- tupoproxy слушает внутренний адрес edge на TCP/18443;
- Management API доступен только на `127.0.0.1:9091`;
- между edge и tupoproxy используется PROXY protocol v2;
- остальные порты и сайты не изменяются.

## Проверка

```bash
sudo systemctl status tupoproxy --no-pager -l
sudo journalctl -u tupoproxy -n 100 --no-pager
sudo /usr/local/lib/tupoproxy/fake-tls-probe.py \
  --connect 203.0.113.10:443 \
  --sni proxy.example.com \
  --secret 00112233445566778899aabbccddeeff
```

Probe формирует настоящий timestamped FakeTLS ClientHello и проверяет ответный
HMAC всего ServerHello flight. Telegram-трафик через probe не передаётся.

## Удаление

`uninstall.sh` удаляет только управляемый FakeTLS-маршрут и файлы tupoproxy.
Reverse proxy, его Docker-контейнер, `/opt/caddy`, другие проекты, сертификаты,
firewall и общие пакеты сохраняются.
