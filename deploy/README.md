# Развёртывание рядом с nginx или Caddy

Основной [`install.sh`](../install.sh) устанавливает готовый бинарник,
настраивает systemd и добавляет в уже работающий reverse proxy сырой
L4-маршрут для FakeTLS SNI.

```bash
curl -fL https://github.com/wasteprince/tupoproxy/releases/latest/download/install.sh \
  | sudo bash
```

## Инвариант FakeTLS

Маршрут tupoproxy никогда не завершает TLS:

```text
ClientHello с decoy SNI
        │
        ├── nginx stream + ssl_preread ── PROXY v2 ── tupoproxy
        └── Caddy layer4 listener wrapper ─ PROXY v2 ─ tupoproxy
```

TLS-терминация применяется только к остальным SNI. Поэтому credential
`ee + secret + hex(SNI)` не конфликтует с сертификатом origin-сайта и не
получает второй ClientHello.

## Автоматически поддерживаемые варианты

- host nginx с модулем `stream_ssl_preread`;
- Docker nginx с этим модулем и постоянным config mount;
- host Caddy, собранный с caddy-l4;
- Docker Caddy с caddy-l4 и постоянным Caddyfile mount;
- Docker Caddy без caddy-l4: модуль добавляется с резервной копией бинарника;
- свободный TCP/443: управляемый Caddy создаётся в `/opt/caddy`.

Активный конфиг изменяется напрямую. Перед reload выполняется `nginx -t` или
`caddy validate`. При ошибке изменения откатываются. Удаление через
[`uninstall.sh`](../uninstall.sh) восстанавливает nginx listeners или удаляет
управляемый маршрут Caddy, но не удаляет сам reverse proxy, его контейнер,
`/opt/caddy` или firewall-правила.

Обычный HTTP `reverse_proxy` для FakeTLS не подходит: он завершает TLS до
tupoproxy. Для стандартного Docker Caddy установщик добавляет caddy-l4 через
`caddy add-package`, перезапускает тот же контейнер и сохраняет исходный
бинарник для удаления или отката.

## Docker

Установщик находит контейнер по фактическому владельцу TCP-порта, а не по
имени или рабочему каталогу. Конфигурация должна находиться в bind mount или
named volume. Изменять только writable layer контейнера небезопасно — после
recreation настройка исчезнет.

Для Docker edge tupoproxy слушает адрес bridge gateway, а PROXY v2 доверяется
только подсети этого bridge. Management API остаётся на loopback.

Bind mount или named volume может быть read-only внутри контейнера:
интегратор находит его источник на хосте, изменяет существующий файл на месте
и сохраняет исходный вариант для отката. Режим mount и остальные файлы reverse
proxy не меняются.

Публичный порт не запрашивается и всегда равен `443`. После recreation
автоматически расширенного Caddy-контейнера повторно запустите установщик:
изменения бинарника внутри writable layer Docker при recreation удаляются.

## Сертификаты и порты

- Сертификат origin продолжает получать существующий nginx/Caddy.
- Управляемый Caddy получает origin-сертификат автоматически.
- Для same-server decoy Certbot выпускает отдельный сертификат.
- Порт `80` и конфигурация остальных проектов не заменяются.
- Если публичный `443` совпал с портом локального decoy, установщик выбирает
  свободный `3443`, `4443`, `5443` или `6443`.

Если HTTP-01 недоступен, используйте DNS-01:

```bash
sudo env TUPOPROXY_CLOUDFLARE_API_TOKEN='TOKEN' bash install.sh \
  --domain proxy.example.com \
  --tls-domain decoy.example.org \
  --email admin@example.com \
  --acme-mode dns \
  --dns-provider cloudflare
```

## Проверка

```bash
openssl s_client -connect SERVER_IP:443 \
  -servername proxy.example.com -alpn h2 </dev/null

openssl s_client -connect SERVER_IP:443 \
  -servername decoy.example.org -alpn h2 </dev/null

sudo -u tupoproxy /usr/local/bin/tupoproxy \
  healthcheck /etc/tupoproxy/config.toml --mode ready
```

Первый TLS-запрос должен вернуть origin-сертификат. Второй проходит через
tupoproxy как неавторизованная проверка и возвращает настоящий decoy.

Ручные файлы в этом каталоге оставлены для нестандартных схем. Для обычной
установки относительные пути `deploy/...` не нужны: используйте release
`install.sh` одной командой.
