#!/usr/bin/env bash
# Runtime deployment functions sourced by the verified tupoproxy installer.

port_is_listening() {
    local port="$1"
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

listener_details() {
    local port="$1"
    ss -H -ltnp "sport = :${port}" 2>/dev/null || true
}

configure_reverse_proxy_mode() {
    local details diagnostics record
    systemctl stop tupoproxy-edge.service 2>/dev/null || true
    if record="$("$EDGE_HELPER" detect --port "$PUBLIC_PORT")"; then
        IFS=$'\t' read -r EDGE_KIND EDGE_TARGET INTERNAL_LISTEN_IP PROXY_TRUSTED_CIDR EDGE_RUNTIME_PORT \
            <<<"$record"
        if [[ "$EDGE_KIND" == "managed-caddy" ]]; then
            EDGE_MODE="managed"
        else
            EDGE_MODE="existing"
        fi
        note "Using ${EDGE_KIND} reverse proxy ${EDGE_TARGET} on TCP/${PUBLIC_PORT}"
    else
        if port_is_listening "$PUBLIC_PORT"; then
            details="$(listener_details "$PUBLIC_PORT")"
            diagnostics="$("$EDGE_HELPER" diagnose --port "$PUBLIC_PORT" || true)"
            die "TCP/${PUBLIC_PORT} is owned by an incompatible service. ${diagnostics:-Listener: ${details:-unknown}}"
        fi
        if ! command -v docker >/dev/null 2>&1; then
            note "Installing Docker for the managed Caddy fallback"
            apt_install docker.io
        fi
        systemctl enable --now docker.service
        record="$("$EDGE_HELPER" managed-record --port "$PUBLIC_PORT")"
        IFS=$'\t' read -r EDGE_KIND EDGE_TARGET INTERNAL_LISTEN_IP PROXY_TRUSTED_CIDR EDGE_RUNTIME_PORT \
            <<<"$record"
        EDGE_MODE="managed"
        note "No compatible reverse proxy was found; Caddy with caddy-l4 will be created in ${MANAGED_CADDY_DIR}"
    fi

    [[ -n "$EDGE_KIND" && -n "$EDGE_TARGET" && -n "$INTERNAL_LISTEN_IP" \
        && -n "$PROXY_TRUSTED_CIDR" && "$EDGE_RUNTIME_PORT" =~ ^[0-9]+$ ]] \
        || die "reverse-proxy discovery returned incomplete data"
    ((EDGE_RUNTIME_PORT >= 1 && EDGE_RUNTIME_PORT <= 65535)) \
        || die "reverse-proxy discovery returned an invalid runtime port"
}

ensure_internal_ports_are_safe() {
    local proxy_port=18443 api_port=9091
    systemctl stop tupoproxy.service 2>/dev/null || true
    if port_is_listening "$proxy_port"; then
        die "internal port ${proxy_port} is already in use"
    fi
    if port_is_listening "$api_port"; then
        die "local API port ${api_port} is already in use"
    fi
}

configure_proxy() {
    local ad_tag_line=""
    local trusted_cidrs='"127.0.0.1/32", "::1/128"'
    [[ -n "$SECRET" ]] || SECRET="$(openssl rand -hex 16)"
    if [[ -n "$AD_TAG" ]]; then
        ad_tag_line="ad_tag = \"${AD_TAG}\""
    fi
    if [[ "$PROXY_TRUSTED_CIDR" != "127.0.0.1/32" ]]; then
        trusted_cidrs="${trusted_cidrs}, \"${PROXY_TRUSTED_CIDR}\""
    fi

    getent group tupoproxy >/dev/null 2>&1 || groupadd --system tupoproxy
    if ! getent passwd tupoproxy >/dev/null 2>&1; then
        useradd --system --gid tupoproxy --home-dir "$STATE_DIR" \
            --shell /usr/sbin/nologin tupoproxy
    fi
    install -d -o tupoproxy -g tupoproxy -m 0750 "$STATE_DIR"
    install -d -o root -g tupoproxy -m 0750 "$CONFIG_DIR"

    cat > "$CONFIG_DIR/config.toml" <<EOF
# Managed by tupoproxy install.sh
[general]
use_middle_proxy = true
log_level = "normal"
${ad_tag_line}

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PUBLIC_HOST}"
public_port = ${PUBLIC_PORT}

[server]
proxy_protocol = true
proxy_protocol_trusted_cidrs = [${trusted_cidrs}]

[[server.listeners]]
ip = "${INTERNAL_LISTEN_IP}"
port = 18443
announce = "${PUBLIC_HOST}"

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]

[censorship]
tls_domain = "${TLS_DOMAIN}"
tls_fingerprints = { "${TLS_DOMAIN}" = "${PROFILE}" }
mask = false
mask_dynamic = false
mask_port = 443
unknown_sni_action = "drop"
tls_emulation = true
tls_front_dir = "${STATE_DIR}/tlsfront-hmac-only"
alpn_enforce = true
tls_new_session_tickets = 0

[access.users]
"${PROXY_USER}" = "${SECRET}"
EOF
    chown root:tupoproxy "$CONFIG_DIR/config.toml"
    chmod 0640 "$CONFIG_DIR/config.toml"
}

configure_services() {
    systemctl disable --now tupoproxy-cover.service >/dev/null 2>&1 || true
    rm -f -- \
        /etc/systemd/system/tupoproxy-cover.service \
        "$CONFIG_DIR/nginx-cover.conf" \
        /etc/letsencrypt/renewal-hooks/deploy/tupoproxy-nginx

    cat > /etc/systemd/system/tupoproxy.service <<EOF
[Unit]
Description=tupoproxy MTProto proxy
Documentation=https://github.com/${REPOSITORY}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tupoproxy
Group=tupoproxy
WorkingDirectory=${STATE_DIR}
ExecStart=${INSTALL_DIR}/tupoproxy --foreground --pid-file /run/tupoproxy/tupoproxy.pid ${CONFIG_DIR}/config.toml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
RuntimeDirectory=tupoproxy
RuntimeDirectoryMode=0750
StateDirectory=tupoproxy
StateDirectoryMode=0750
LimitNOFILE=262144
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl disable --now tupoproxy-edge.service >/dev/null 2>&1 || true
    rm -f -- "$CONFIG_DIR/haproxy.cfg" /etc/systemd/system/tupoproxy-edge.service
    systemctl daemon-reload
    systemctl enable tupoproxy.service
}

configure_public_edge() {
    local backend="${INTERNAL_LISTEN_IP}:18443"
    if [[ "$EDGE_MODE" == "existing" ]]; then
        "$EDGE_HELPER" remove --state-dir "$STATE_DIR"
        "$EDGE_HELPER" apply \
            --port "$PUBLIC_PORT" \
            --tls-domain "$TLS_DOMAIN" \
            --backend "$backend" \
            --state-dir "$STATE_DIR"
        return 0
    fi
    [[ "$EDGE_MODE" == "managed" ]] || die "unknown reverse-proxy mode: ${EDGE_MODE}"
    "$EDGE_HELPER" provision-caddy \
        --domain "$DOMAIN" \
        --tls-domain "$TLS_DOMAIN" \
        --backend "$backend" \
        --state-dir "$STATE_DIR" \
        --opt-dir "$MANAGED_CADDY_DIR"
}

open_firewall_ports() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${PUBLIC_PORT}/tcp"
    fi
}

restart_service_or_die() {
    local service="$1"
    if systemctl restart "$service"; then
        return 0
    fi

    printf '\n----- %s status -----\n' "$service" >&2
    systemctl --no-pager --full status "$service" >&2 || true
    printf '\n----- %s recent journal -----\n' "$service" >&2
    journalctl --no-pager --full -n 80 -u "$service" >&2 || true
    die "${service} failed to start; diagnostics are printed above"
}

print_startup_diagnostics() {
    printf '\n----- tupoproxy.service status -----\n' >&2
    systemctl --no-pager --full status tupoproxy.service >&2 || true
    printf '\n----- tupoproxy.service recent journal -----\n' >&2
    journalctl --no-pager --full -n 40 -u tupoproxy.service >&2 || true
    if [[ "$EDGE_MODE" == "managed" ]]; then
        printf '\n----- tupoproxy-caddy logs -----\n' >&2
        docker logs --tail 80 tupoproxy-caddy >&2 || true
    else
        printf '\n----- reverse-proxy integration -----\n' >&2
        sed -n '1,200p' "$STATE_DIR/edge-integration.json" >&2 || true
    fi
}

verify_fake_tls_route() {
    local connect_host="$PUBLIC_HOST" deadline last_output=""

    if [[ "$EDGE_MODE" == "managed" ]]; then
        connect_host="127.0.0.1"
    fi

    note "Verifying the authenticated FakeTLS route through the reverse proxy"
    deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        if last_output="$("$FAKETLS_PROBE" \
            --connect "${connect_host}:${PUBLIC_PORT}" \
            --sni "$TLS_DOMAIN" \
            --secret "$SECRET" \
            --timeout 5 2>&1)"; then
            printf '%s via %s:%s (public endpoint %s:%s)\n' \
                "$last_output" "$connect_host" "$PUBLIC_PORT" "$PUBLIC_HOST" "$PUBLIC_PORT"
            return 0
        fi
        sleep 2
    done
    printf 'Last FakeTLS probe output:\n%s\n' "$last_output" >&2
    fail_public_verification \
        "authenticated FakeTLS did not pass through ${connect_host}:${PUBLIC_PORT} for SNI ${TLS_DOMAIN}"
}

fail_public_verification() {
    local message="$1"
    print_startup_diagnostics
    if "$EDGE_HELPER" remove --state-dir "$STATE_DIR"; then
        die "$message; the reverse-proxy change was rolled back"
    fi
    die "$message; automatic reverse-proxy rollback also failed, inspect the diagnostics above"
}

prompt_bot_registration() {
    local value
    if [[ -n "$AD_TAG" || ("$SETUP_WIZARD" != "1" && "$INTERACTIVE_MODE" != "1") ]]; then
        return 0
    fi

    printf '\n============================================================\n' >/dev/tty
    printf '@MTProxybot registration\n' >/dev/tty
    printf 'Proxy address for the bot (host:port): %s:%s\n' "$PUBLIC_HOST" "$PUBLIC_PORT" >/dev/tty
    printf 'When @MTProxybot says:\n' >/dev/tty
    printf 'Now please specify its secret in hex format.\n' >/dev/tty
    printf 'send exactly this 32-character secret (without ee or the domain):\n' >/dev/tty
    printf '%s\n' "$SECRET" >/dev/tty
    printf '============================================================\n' >/dev/tty
    while true; do
        read -r -p "Paste the advertising tag returned by @MTProxybot (Enter to skip): " value </dev/tty
        [[ -n "$value" ]] || return 0
        if [[ ! "$value" =~ ^[A-Fa-f0-9]{32}$ ]]; then
            printf 'The tag must contain exactly 32 hex characters. Try again.\n' >/dev/tty
            continue
        fi
        if [[ "${value,,}" == "00000000000000000000000000000000" ]]; then
            printf 'The all-zero tag is not valid. Paste the tag issued by @MTProxybot.\n' >/dev/tty
            continue
        fi
        AD_TAG="${value,,}"
        break
    done
    # shellcheck disable=SC2034  # Consumed by the parent installer after sourcing.
    AD_TAG_CHANGED=1
}

telegram_proxy_link() {
    local encoded_secret
    encoded_secret="$(python3 - "$SECRET" "$TLS_DOMAIN" <<'PY'
import base64
import sys

payload = bytes.fromhex("ee" + sys.argv[1]) + sys.argv[2].encode("ascii")
print(base64.urlsafe_b64encode(payload).decode("ascii").rstrip("="))
PY
)"
    printf 'tg://proxy?server=%s&port=%s&secret=%s' \
        "$PUBLIC_HOST" "$PUBLIC_PORT" "$encoded_secret"
}

save_summary() {
    local telegram_link
    telegram_link="$(telegram_proxy_link)"
    cat > "$CONFIG_DIR/INSTALLATION.txt" <<EOF
tupoproxy installation
Domain: ${DOMAIN}
TLS decoy domain: ${TLS_DOMAIN}
Public host: ${PUBLIC_HOST}
Public port: ${PUBLIC_PORT}
Edge mode: ${EDGE_MODE}
Edge kind: ${EDGE_KIND}
Edge target: ${EDGE_TARGET}
Edge runtime port: ${EDGE_RUNTIME_PORT}
TLS profile: ${PROFILE}
Credential user: ${PROXY_USER}
Secret: ${SECRET}
Advertising tag: ${AD_TAG}
FakeTLS reject policy: drop

@MTProxybot registration:
When the bot says "Now please specify its secret in hex format.", send:
${SECRET}

Telegram link:
${telegram_link}

Logs:
journalctl -u tupoproxy -f
EOF
    chmod 0600 "$CONFIG_DIR/INSTALLATION.txt"
}

write_summary() {
    local telegram_link
    telegram_link="$(telegram_proxy_link)"
    save_summary

    printf '\n============================================================\n'
    printf 'tupoproxy is installed\n'
    printf 'Public endpoint: %s:%s\n' "$PUBLIC_HOST" "$PUBLIC_PORT"
    printf 'Reverse proxy: %s (%s, %s)\n' "$EDGE_KIND" "$EDGE_MODE" "$EDGE_TARGET"
    printf 'FakeTLS SNI: %s\n' "$TLS_DOMAIN"
    printf 'Invalid FakeTLS clients: dropped without TLS fallback\n'
    printf 'TLS profile: %s\n' "$PROFILE"
    if [[ -n "$AD_TAG" ]]; then
        printf 'Sponsored-channel tag: configured\n'
    fi
    printf 'When @MTProxybot says "Now please specify its secret in hex format.", send:\n'
    printf '%s\n' "$SECRET"
    printf '(32 hex characters; without ee or the domain)\n'
    printf 'Telegram link:\n%s\n' "$telegram_link"
    printf 'Saved securely in %s/INSTALLATION.txt\n' "$CONFIG_DIR"
    printf '============================================================\n'
}
