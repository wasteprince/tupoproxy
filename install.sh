#!/usr/bin/env bash
# Automated Debian/Ubuntu installer for prebuilt tupoproxy releases.
set -Eeuo pipefail
umask 027

readonly REPOSITORY="wasteprince/tupoproxy"
readonly INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
readonly CONFIG_DIR="${CONFIG_DIR:-/etc/tupoproxy}"
readonly STATE_DIR="${STATE_DIR:-/var/lib/tupoproxy}"

DOMAIN=""
EMAIL=""
PROFILE="chrome"
PROXY_USER="user"
PUBLIC_PORT=""
SECRET=""
CERT_FULLCHAIN=""
CERT_KEY=""
ACME_MODE="auto"
ACME_WEBROOT=""
DNS_PROVIDER=""
DNS_CREDENTIALS=""
DNS_PROPAGATION_SECONDS="60"
CLOUDFLARE_API_TOKEN="${TUPOPROXY_CLOUDFLARE_API_TOKEN:-}"
NO_START=0
BINARY_ONLY=0
INSTALL_TEMP_DIR=""
CREATED_POLICY_RC_D=0
APT_UPDATED=0
SETUP_WIZARD=0
PROFILE_SET=0
PROXY_USER_SET=0
NGINX_WAS_INSTALLED=0
HAPROXY_WAS_INSTALLED=0

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [options]

Required interactively or as flags:
  --domain NAME          Domain used in the Telegram ee credential
  --email ADDRESS        ACME account e-mail (not needed with --cert-*)

Optional:
  --profile NAME         chrome|firefox|compat|legacy (default: chrome)
  --user NAME            Credential label (default: user)
  --port PORT            Public TCP port (default: 443, or a free fallback)
  --secret HEX           Existing 16-byte secret (default: generated)
  --cert-fullchain PATH  Existing PEM certificate chain
  --cert-key PATH        Existing PEM private key
  --acme-mode MODE       auto|standalone|nginx|apache|webroot|dns|manual-dns
  --acme-webroot PATH    Existing public webroot (requires --acme-mode webroot)
  --dns-provider NAME    Certbot DNS plugin, for example cloudflare or route53
  --dns-credentials PATH Provider credentials file (not used by route53)
  --dns-propagation SEC  DNS propagation wait (default: 60)
  --cloudflare-api-token TOKEN
                         Convenience credential for the Cloudflare DNS plugin
  --binary-only          Install the prebuilt binary without server setup
  --no-start             Write configuration without starting services
  -h, --help             Show this help

Examples:
  sudo bash install.sh --domain proxy.example.com --email admin@example.com
  sudo bash install.sh --domain proxy.example.com --email admin@example.com \
    --port 8443 --acme-mode dns --dns-provider cloudflare \
    --dns-credentials /root/cloudflare.ini
  curl -fsSL https://raw.githubusercontent.com/wasteprince/tupoproxy/main/install.sh \
    | sudo bash -s -- --domain proxy.example.com --email admin@example.com
EOF
}

die() {
    printf 'tupoproxy installer: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '\n==> %s\n' "$*"
}

on_error() {
    local status=$?
    local line="$1"
    printf 'tupoproxy installer: command failed at line %s (exit %s)\n' \
        "$line" "$status" >&2
    exit "$status"
}
trap 'on_error "$LINENO"' ERR

while (($#)); do
    case "$1" in
        --domain)
            (($# >= 2)) || die "--domain requires a value"
            DOMAIN="$2"
            shift 2
            ;;
        --email)
            (($# >= 2)) || die "--email requires a value"
            EMAIL="$2"
            shift 2
            ;;
        --profile)
            (($# >= 2)) || die "--profile requires a value"
            PROFILE="$2"
            PROFILE_SET=1
            shift 2
            ;;
        --user)
            (($# >= 2)) || die "--user requires a value"
            PROXY_USER="$2"
            PROXY_USER_SET=1
            shift 2
            ;;
        --port)
            (($# >= 2)) || die "--port requires a value"
            PUBLIC_PORT="$2"
            shift 2
            ;;
        --secret)
            (($# >= 2)) || die "--secret requires a value"
            SECRET="$2"
            shift 2
            ;;
        --cert-fullchain)
            (($# >= 2)) || die "--cert-fullchain requires a value"
            CERT_FULLCHAIN="$2"
            shift 2
            ;;
        --cert-key)
            (($# >= 2)) || die "--cert-key requires a value"
            CERT_KEY="$2"
            shift 2
            ;;
        --acme-mode)
            (($# >= 2)) || die "--acme-mode requires a value"
            ACME_MODE="$2"
            shift 2
            ;;
        --acme-webroot)
            (($# >= 2)) || die "--acme-webroot requires a value"
            ACME_WEBROOT="$2"
            shift 2
            ;;
        --dns-provider)
            (($# >= 2)) || die "--dns-provider requires a value"
            DNS_PROVIDER="$2"
            shift 2
            ;;
        --dns-credentials)
            (($# >= 2)) || die "--dns-credentials requires a value"
            DNS_CREDENTIALS="$2"
            shift 2
            ;;
        --dns-propagation)
            (($# >= 2)) || die "--dns-propagation requires a value"
            DNS_PROPAGATION_SECONDS="$2"
            shift 2
            ;;
        --cloudflare-api-token)
            (($# >= 2)) || die "--cloudflare-api-token requires a value"
            CLOUDFLARE_API_TOKEN="$2"
            shift 2
            ;;
        --binary-only)
            BINARY_ONLY=1
            shift
            ;;
        --no-start)
            NO_START=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die "run this installer as root (for example: sudo bash install.sh)"

if [[ ! -r /etc/os-release ]]; then
    die "only Debian and Ubuntu are supported by the automated installer"
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|*:debian*) ;;
    *) die "unsupported distribution '${ID:-unknown}'; use install-source.sh instead" ;;
esac

prompt_value() {
    local variable_name="$1"
    local prompt="$2"
    local value="${!variable_name}"
    if [[ -n "$value" ]]; then
        return
    fi
    [[ -r /dev/tty ]] || die "$prompt must be supplied as a command-line option"
    read -r -p "$prompt: " value </dev/tty
    printf -v "$variable_name" '%s' "$value"
    SETUP_WIZARD=1
}

prompt_public_port() {
    local value
    [[ -z "$PUBLIC_PORT" && "$SETUP_WIZARD" == "1" ]] || return
    read -r -p "Public proxy port [auto]: " value </dev/tty
    PUBLIC_PORT="$value"
}

installation_value() {
    local label="$1"
    local summary_file="$CONFIG_DIR/INSTALLATION.txt"
    [[ -r "$summary_file" ]] || return 0
    sed -n "s/^${label}: //p" "$summary_file" | head -n 1
}

load_existing_installation() {
    local saved_fullchain saved_key saved_value
    [[ -r "$CONFIG_DIR/INSTALLATION.txt" ]] || return

    [[ -n "$DOMAIN" ]] || DOMAIN="$(installation_value Domain)"
    [[ -n "$EMAIL" ]] || EMAIL="$(installation_value 'ACME e-mail')"
    [[ -n "$PUBLIC_PORT" ]] || PUBLIC_PORT="$(installation_value 'Public port')"
    [[ -n "$SECRET" ]] || SECRET="$(installation_value Secret)"
    if ((!PROFILE_SET)); then
        saved_value="$(installation_value 'TLS profile')"
        [[ -z "$saved_value" ]] || PROFILE="$saved_value"
    fi
    if ((!PROXY_USER_SET)); then
        saved_value="$(installation_value 'Credential user')"
        [[ -z "$saved_value" ]] || PROXY_USER="$saved_value"
    fi

    if [[ -z "$CERT_FULLCHAIN" && -z "$CERT_KEY" ]]; then
        saved_fullchain="$(installation_value 'Certificate chain')"
        saved_key="$(installation_value 'Certificate key')"
        if [[ -r "$saved_fullchain" && -r "$saved_key" ]]; then
            CERT_FULLCHAIN="$saved_fullchain"
            CERT_KEY="$saved_key"
        fi
    fi
}

validate_domain() {
    [[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "invalid domain: $DOMAIN"
    DOMAIN="${DOMAIN,,}"
}

validate_inputs() {
    case "$PROFILE" in
        chrome|firefox|compat|legacy) ;;
        *) die "profile must be chrome, firefox, compat, or legacy" ;;
    esac
    [[ "$PROXY_USER" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "invalid credential user label"
    if [[ -n "$PUBLIC_PORT" ]]; then
        [[ "$PUBLIC_PORT" =~ ^[0-9]+$ ]] || die "port must be numeric"
        ((PUBLIC_PORT >= 1 && PUBLIC_PORT <= 65535)) || die "port must be between 1 and 65535"
    fi
    if [[ -n "$SECRET" ]]; then
        [[ "$SECRET" =~ ^[A-Fa-f0-9]{32}$ ]] || die "secret must be exactly 32 hex characters"
        SECRET="${SECRET,,}"
    fi
    if [[ -n "$CERT_FULLCHAIN" || -n "$CERT_KEY" ]]; then
        [[ -n "$CERT_FULLCHAIN" && -n "$CERT_KEY" ]] \
            || die "--cert-fullchain and --cert-key must be provided together"
        [[ "$CERT_FULLCHAIN" =~ ^/[A-Za-z0-9_./-]+$ && "$CERT_KEY" =~ ^/[A-Za-z0-9_./-]+$ ]] \
            || die "certificate paths must be absolute and contain only letters, digits, '_', '-', '.', and '/'"
        [[ -r "$CERT_FULLCHAIN" && -r "$CERT_KEY" ]] || die "provided certificate files are not readable"
    else
        [[ -n "$EMAIL" ]] || die "ACME e-mail address is required"
        [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
            || die "invalid ACME e-mail address"
    fi
    case "$ACME_MODE" in
        auto|standalone|nginx|apache|webroot|dns|manual-dns|existing) ;;
        *) die "ACME mode must be auto, standalone, nginx, apache, webroot, dns, or manual-dns" ;;
    esac
    [[ "$DNS_PROPAGATION_SECONDS" =~ ^[0-9]+$ ]] \
        || die "DNS propagation wait must be numeric"
    ((DNS_PROPAGATION_SECONDS >= 10 && DNS_PROPAGATION_SECONDS <= 3600)) \
        || die "DNS propagation wait must be between 10 and 3600 seconds"
    if [[ -n "$DNS_PROVIDER" ]]; then
        [[ "$DNS_PROVIDER" =~ ^[a-z0-9-]+$ ]] || die "invalid DNS provider name"
    fi
    if [[ -n "$DNS_CREDENTIALS" ]]; then
        [[ "$DNS_CREDENTIALS" =~ ^/[A-Za-z0-9_./-]+$ ]] \
            || die "DNS credentials path must be absolute and contain only letters, digits, '_', '-', '.', and '/'"
        [[ -r "$DNS_CREDENTIALS" ]] || die "DNS credentials file is not readable"
    fi
    if [[ -n "$CLOUDFLARE_API_TOKEN" ]]; then
        [[ "$CLOUDFLARE_API_TOKEN" =~ ^[A-Za-z0-9_.-]{20,256}$ ]] \
            || die "invalid Cloudflare API token format"
    fi
    if [[ "$ACME_MODE" == "existing" && -z "$CERT_FULLCHAIN" ]]; then
        die "the internal 'existing' ACME mode requires --cert-fullchain and --cert-key"
    fi
    if [[ "$ACME_MODE" == "webroot" ]]; then
        [[ "$ACME_WEBROOT" =~ ^/[A-Za-z0-9_./-]+$ && -d "$ACME_WEBROOT" ]] \
            || die "--acme-webroot must point to an existing absolute directory"
    fi
}

cleanup() {
    if ((CREATED_POLICY_RC_D)) && [[ -f /usr/sbin/policy-rc.d ]] \
        && grep -q '^# Managed temporarily by tupoproxy install.sh$' /usr/sbin/policy-rc.d; then
        rm -f -- /usr/sbin/policy-rc.d
    fi
    if [[ -n "${INSTALL_TEMP_DIR:-}" && -d "$INSTALL_TEMP_DIR" \
        && "$INSTALL_TEMP_DIR" == /tmp/tupoproxy-install.* ]]; then
        rm -rf -- "$INSTALL_TEMP_DIR"
    fi
}
trap cleanup EXIT

apt_install() {
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '%s\n' '#!/bin/sh' '# Managed temporarily by tupoproxy install.sh' 'exit 101' \
            >/usr/sbin/policy-rc.d
        chmod 0755 /usr/sbin/policy-rc.d
        CREATED_POLICY_RC_D=1
    fi
    if ((!APT_UPDATED)); then
        apt-get update
        APT_UPDATED=1
    fi
    apt-get install -y --no-install-recommends "$@"
    if ((CREATED_POLICY_RC_D)); then
        rm -f -- /usr/sbin/policy-rc.d
        CREATED_POLICY_RC_D=0
    fi
}

package_is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

download_file() {
    local url="$1"
    local destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --retry 3 \
            --connect-timeout 15 --output "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --tries=3 --timeout=15 --output-document="$destination" "$url"
    else
        die "curl or wget is required"
    fi
}

install_prebuilt_binary() {
    local machine target asset release_base checksum_line
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) target="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
        *) die "no prebuilt binary for architecture: $machine" ;;
    esac

    asset="tupoproxy-${target}.tar.gz"
    if [[ -n "${TUPOPROXY_VERSION:-}" && "${TUPOPROXY_VERSION}" != "latest" ]]; then
        release_base="https://github.com/${REPOSITORY}/releases/download/${TUPOPROXY_VERSION}"
    else
        release_base="https://github.com/${REPOSITORY}/releases/latest/download"
    fi

    INSTALL_TEMP_DIR="$(mktemp -d -t tupoproxy-install.XXXXXXXX)"
    download_file "${release_base}/${asset}" "${INSTALL_TEMP_DIR}/${asset}"
    download_file "${release_base}/CHECKSUMS.txt" "${INSTALL_TEMP_DIR}/CHECKSUMS.txt"

    checksum_line="$(grep -E "^[0-9a-f]{64}  ${asset}$" "${INSTALL_TEMP_DIR}/CHECKSUMS.txt" || true)"
    [[ -n "$checksum_line" ]] || die "release checksum for ${asset} is missing"
    printf '%s\n' "$checksum_line" >"${INSTALL_TEMP_DIR}/asset.sha256"
    (cd "$INSTALL_TEMP_DIR" && sha256sum --check asset.sha256)

    mkdir -p "${INSTALL_TEMP_DIR}/unpack"
    tar -xzf "${INSTALL_TEMP_DIR}/${asset}" -C "${INSTALL_TEMP_DIR}/unpack"
    [[ -f "${INSTALL_TEMP_DIR}/unpack/tupoproxy" ]] || die "release archive has no tupoproxy binary"

    install -d -m 0755 "$INSTALL_DIR"
    install -m 0755 "${INSTALL_TEMP_DIR}/unpack/tupoproxy" "$INSTALL_DIR/tupoproxy"
    "$INSTALL_DIR/tupoproxy" --version
    rm -rf -- "$INSTALL_TEMP_DIR"
    INSTALL_TEMP_DIR=""
}

port_is_listening() {
    local port="$1"
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

listener_details() {
    local port="$1"
    ss -H -ltnp "sport = :${port}" 2>/dev/null || true
}

choose_public_port() {
    local candidate
    systemctl stop tupoproxy-edge.service 2>/dev/null || true
    if [[ -n "$PUBLIC_PORT" ]]; then
        port_is_listening "$PUBLIC_PORT" && die "requested public port ${PUBLIC_PORT} is already in use"
        return
    fi
    for candidate in 443 8443 2053 2083 2087 2096; do
        if ! port_is_listening "$candidate"; then
            PUBLIC_PORT="$candidate"
            if [[ "$candidate" != "443" ]]; then
                note "Port 443 is occupied; selected free proxy port ${candidate}"
            fi
            return
        fi
    done
    die "none of the supported public ports is free; specify one with --port"
}

ensure_internal_ports_are_safe() {
    local proxy_port=18443 cover_port=19443 api_port=9091
    systemctl stop tupoproxy.service tupoproxy-cover.service 2>/dev/null || true
    if port_is_listening "$proxy_port"; then
        die "internal port ${proxy_port} is already in use"
    fi
    if port_is_listening "$cover_port"; then
        die "internal port ${cover_port} is already in use"
    fi
    if port_is_listening "$api_port"; then
        die "local API port ${api_port} is already in use"
    fi
}

prompt_dns_settings() {
    local value
    if [[ -z "$DNS_PROVIDER" ]]; then
        [[ -r /dev/tty ]] \
            || die "port 80 is occupied; use --dns-provider, --acme-mode webroot, or existing --cert-* files"
        printf 'Port 80 cannot be used without touching the existing service.\n' >/dev/tty
        printf 'DNS provider plugin (cloudflare, route53, digitalocean, ...), or manual [manual]: ' >/dev/tty
        read -r value </dev/tty
        if [[ -z "$value" || "$value" == "manual" ]]; then
            ACME_MODE="manual-dns"
            return
        fi
        DNS_PROVIDER="${value,,}"
    fi

    ACME_MODE="dns"
    if [[ "$DNS_PROVIDER" == "cloudflare" && -z "$DNS_CREDENTIALS" \
        && -z "$CLOUDFLARE_API_TOKEN" ]]; then
        [[ -r /dev/tty ]] \
            || die "set TUPOPROXY_CLOUDFLARE_API_TOKEN or provide --dns-credentials"
        read -r -s -p "Cloudflare DNS API token: " CLOUDFLARE_API_TOKEN </dev/tty
        printf '\n' >/dev/tty
    elif [[ "$DNS_PROVIDER" != "route53" && -z "$DNS_CREDENTIALS" ]]; then
        [[ -r /dev/tty ]] \
            || die "--dns-credentials is required for DNS provider ${DNS_PROVIDER}"
        read -r -p "Absolute path to ${DNS_PROVIDER} credentials file: " DNS_CREDENTIALS </dev/tty
    fi
}

choose_acme_mode() {
    local details
    if [[ -n "$CERT_FULLCHAIN" ]]; then
        ACME_MODE="existing"
        return
    fi

    if [[ "$ACME_MODE" == "dns" ]]; then
        prompt_dns_settings
        return
    fi
    [[ "$ACME_MODE" == "auto" ]] || return

    if [[ -n "$DNS_PROVIDER" ]]; then
        ACME_MODE="dns"
        prompt_dns_settings
        return
    fi
    if ! port_is_listening 80; then
        ACME_MODE="standalone"
        return
    fi

    details="$(listener_details 80)"
    if grep -qi 'nginx' <<<"$details"; then
        ACME_MODE="nginx"
    elif grep -Eqi 'apache2|httpd' <<<"$details"; then
        ACME_MODE="apache"
    else
        prompt_dns_settings
    fi
}

install_dns_plugin() {
    case "$DNS_PROVIDER" in
        cloudflare|digitalocean|dnsimple|dnsmadeeasy|gehirn|google|linode|luadns|nsone|ovh|rfc2136|route53)
            apt_install "python3-certbot-dns-${DNS_PROVIDER}"
            ;;
        *)
            die "unsupported packaged DNS plugin '${DNS_PROVIDER}'; use manual-dns or existing --cert-* files"
            ;;
    esac
}

install_acme_plugin() {
    case "$ACME_MODE" in
        nginx) apt_install python3-certbot-nginx ;;
        apache) apt_install python3-certbot-apache ;;
        dns) install_dns_plugin ;;
    esac
}

configure_acme() {
    local managed_credentials="/etc/letsencrypt/tupoproxy-dns.ini"
    local dns_option
    local -a certbot_args

    if [[ -n "$CERT_FULLCHAIN" ]]; then
        return
    fi

    certbot_args=(certonly --agree-tos --keep-until-expiring --email "$EMAIL" -d "$DOMAIN")
    case "$ACME_MODE" in
        standalone)
            port_is_listening 80 && die "port 80 became occupied; use DNS validation or select another ACME mode"
            certbot "${certbot_args[@]}" --non-interactive --standalone --preferred-challenges http
            ;;
        nginx)
            listener_details 80 | grep -qi nginx \
                || die "--acme-mode nginx requires nginx to be serving port 80"
            certbot "${certbot_args[@]}" --non-interactive --nginx --preferred-challenges http
            ;;
        apache)
            listener_details 80 | grep -Eqi 'apache2|httpd' \
                || die "--acme-mode apache requires Apache to be serving port 80"
            certbot "${certbot_args[@]}" --non-interactive --apache --preferred-challenges http
            ;;
        webroot)
            certbot "${certbot_args[@]}" --non-interactive --webroot \
                --webroot-path "$ACME_WEBROOT" --preferred-challenges http
            ;;
        dns)
            install -d -m 0700 /etc/letsencrypt
            dns_option="--dns-${DNS_PROVIDER}"
            if [[ "$DNS_PROVIDER" == "cloudflare" && -n "$CLOUDFLARE_API_TOKEN" ]]; then
                printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" >"$managed_credentials"
                chmod 0600 "$managed_credentials"
                DNS_CREDENTIALS="$managed_credentials"
            elif [[ -n "$DNS_CREDENTIALS" && "$DNS_CREDENTIALS" != "$managed_credentials" ]]; then
                install -m 0600 "$DNS_CREDENTIALS" "$managed_credentials"
                DNS_CREDENTIALS="$managed_credentials"
            fi

            certbot_args+=(--non-interactive "$dns_option")
            if [[ "$DNS_PROVIDER" != "route53" ]]; then
                certbot_args+=("${dns_option}-propagation-seconds" "$DNS_PROPAGATION_SECONDS")
            fi
            if [[ "$DNS_PROVIDER" != "route53" ]]; then
                [[ -n "$DNS_CREDENTIALS" ]] \
                    || die "DNS credentials are required for provider ${DNS_PROVIDER}"
                certbot_args+=("${dns_option}-credentials" "$DNS_CREDENTIALS")
            fi
            certbot "${certbot_args[@]}"
            ;;
        manual-dns)
            [[ -r /dev/tty ]] || die "manual DNS validation requires an interactive terminal"
            note "Certbot will show a TXT record; add it in your DNS panel and continue"
            certbot "${certbot_args[@]}" --manual --preferred-challenges dns </dev/tty
            ;;
        *) die "internal error: unresolved ACME mode ${ACME_MODE}" ;;
    esac

    CERT_FULLCHAIN="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    CERT_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    [[ -r "$CERT_FULLCHAIN" && -r "$CERT_KEY" ]] || die "certificate issuance did not produce readable files"
}

configure_cover_site() {
    install -d -m 0755 /run/tupoproxy-cover
    cat > "$CONFIG_DIR/nginx-cover.conf" <<EOF
# Managed by tupoproxy install.sh
user www-data;
worker_processes auto;
pid /run/tupoproxy-cover/nginx.pid;
error_log stderr warn;

events {
    worker_connections 1024;
}

http {
    access_log off;
    server_tokens off;

    server {
        listen 127.0.0.1:19443 ssl;
        server_name ${DOMAIN};

        ssl_certificate "${CERT_FULLCHAIN}";
        ssl_certificate_key "${CERT_KEY}";
        ssl_protocols TLSv1.2 TLSv1.3;

        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
        default_type text/html;
        return 200 '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>';
    }
}
EOF

    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/tupoproxy-nginx <<'EOF'
#!/bin/sh
systemctl reload tupoproxy-cover.service
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/tupoproxy-nginx
    nginx -t -c "$CONFIG_DIR/nginx-cover.conf"
}

configure_proxy() {
    if ! getent ahosts "$DOMAIN" >/dev/null 2>&1; then
        die "domain ${DOMAIN} does not resolve; create its DNS A/AAAA record first"
    fi
    [[ -n "$SECRET" ]] || SECRET="$(openssl rand -hex 16)"

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

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${DOMAIN}"
public_port = ${PUBLIC_PORT}

[server]
proxy_protocol = true
proxy_protocol_trusted_cidrs = ["127.0.0.1/32", "::1/128"]

[[server.listeners]]
ip = "127.0.0.1"
port = 18443
announce = "${DOMAIN}"

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]

[censorship]
tls_domain = "${DOMAIN}"
tls_fingerprints = { "${DOMAIN}" = "${PROFILE}" }
mask = true
mask_dynamic = false
mask_host = "127.0.0.1"
mask_port = 19443
unknown_sni_action = "mask"
tls_emulation = true
tls_front_dir = "${STATE_DIR}/tlsfront"
alpn_enforce = true

[access.users]
"${PROXY_USER}" = "${SECRET}"
EOF
    chown root:tupoproxy "$CONFIG_DIR/config.toml"
    chmod 0640 "$CONFIG_DIR/config.toml"
}

configure_services() {
    cat > /etc/systemd/system/tupoproxy-cover.service <<EOF
[Unit]
Description=tupoproxy isolated HTTPS cover
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/nginx -c ${CONFIG_DIR}/nginx-cover.conf -g "daemon off;"
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
RuntimeDirectory=tupoproxy-cover
RuntimeDirectoryMode=0755
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

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/tupoproxy.service <<EOF
[Unit]
Description=tupoproxy MTProto proxy
Documentation=https://github.com/${REPOSITORY}
After=network-online.target tupoproxy-cover.service
Wants=network-online.target
Requires=tupoproxy-cover.service

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

    cat > "$CONFIG_DIR/haproxy.cfg" <<EOF
# Managed by tupoproxy install.sh
global
    log stdout format raw local0
    user haproxy
    group haproxy

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client 2m
    timeout server 2m

frontend tupoproxy_public
    bind :${PUBLIC_PORT}
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    acl credential_sni req.ssl_sni -i ${DOMAIN}
    use_backend tupoproxy_backend if credential_sni
    default_backend tupoproxy_cover

backend tupoproxy_backend
    server tupoproxy 127.0.0.1:18443 send-proxy-v2 check

backend tupoproxy_cover
    server cover 127.0.0.1:19443 check
EOF
    chown root:tupoproxy "$CONFIG_DIR/haproxy.cfg"
    chmod 0640 "$CONFIG_DIR/haproxy.cfg"

    cat > /etc/systemd/system/tupoproxy-edge.service <<EOF
[Unit]
Description=tupoproxy public TLS edge
After=network-online.target tupoproxy-cover.service tupoproxy.service
Requires=tupoproxy-cover.service tupoproxy.service

[Service]
Type=notify
ExecStart=/usr/sbin/haproxy -Ws -f ${CONFIG_DIR}/haproxy.cfg -p /run/tupoproxy-edge.pid
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=on-failure
RestartSec=5s
RuntimeDirectory=tupoproxy-edge
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

    haproxy -c -f "$CONFIG_DIR/haproxy.cfg"
    systemctl daemon-reload
    systemctl enable tupoproxy-cover.service tupoproxy.service tupoproxy-edge.service
}

open_firewall_ports() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        case "$ACME_MODE" in
            standalone|nginx|apache|webroot) ufw allow 80/tcp ;;
        esac
        ufw allow "${PUBLIC_PORT}/tcp"
    fi
}

write_summary() {
    local domain_hex telegram_link
    domain_hex="$(printf '%s' "$DOMAIN" | od -An -tx1 | tr -d ' \n')"
    telegram_link="tg://proxy?server=${DOMAIN}&port=${PUBLIC_PORT}&secret=ee${SECRET}${domain_hex}"
    cat > "$CONFIG_DIR/INSTALLATION.txt" <<EOF
tupoproxy installation
Domain: ${DOMAIN}
ACME e-mail: ${EMAIL}
Public port: ${PUBLIC_PORT}
TLS profile: ${PROFILE}
Credential user: ${PROXY_USER}
Secret: ${SECRET}
Certificate chain: ${CERT_FULLCHAIN}
Certificate key: ${CERT_KEY}

Telegram link:
${telegram_link}

Logs:
journalctl -u tupoproxy -f
EOF
    chmod 0600 "$CONFIG_DIR/INSTALLATION.txt"

    printf '\n============================================================\n'
    printf 'tupoproxy is installed\n'
    printf 'Public endpoint: %s:%s\n' "$DOMAIN" "$PUBLIC_PORT"
    printf 'TLS profile: %s\n' "$PROFILE"
    printf 'Certificate mode: %s\n' "$ACME_MODE"
    printf 'Telegram link:\n%s\n' "$telegram_link"
    printf 'Saved securely in %s/INSTALLATION.txt\n' "$CONFIG_DIR"
    printf '============================================================\n'
}

export DEBIAN_FRONTEND=noninteractive

if ((!BINARY_ONLY)); then
    note "Starting automated tupoproxy setup"
    load_existing_installation
    prompt_value DOMAIN "Proxy domain"
    validate_domain
    if [[ -z "$CERT_FULLCHAIN" ]]; then
        prompt_value EMAIL "ACME e-mail"
    fi
    prompt_public_port
    validate_inputs
fi

note "Installing operating-system dependencies"
if ((BINARY_ONLY)); then
    apt_install ca-certificates curl tar coreutils
else
    package_is_installed nginx && NGINX_WAS_INSTALLED=1
    package_is_installed haproxy && HAPROXY_WAS_INSTALLED=1
    apt_install \
        ca-certificates curl tar coreutils openssl iproute2 nginx haproxy certbot
    if ((!NGINX_WAS_INSTALLED)); then
        systemctl disable --now nginx.service >/dev/null 2>&1 || true
    fi
    if ((!HAPROXY_WAS_INSTALLED)); then
        systemctl disable --now haproxy.service >/dev/null 2>&1 || true
    fi
fi

note "Installing the prebuilt static binary"
install_prebuilt_binary

if ((BINARY_ONLY)); then
    note "Binary-only installation complete"
    exit 0
fi

choose_public_port
ensure_internal_ports_are_safe
choose_acme_mode
validate_inputs
install_acme_plugin

note "Preparing certificate and HTTPS cover"
configure_acme
configure_cover_site

note "Writing tupoproxy and edge configurations"
configure_proxy
configure_services
open_firewall_ports

if ((NO_START)); then
    note "Configuration complete; services were not started (--no-start)"
else
    note "Starting tupoproxy"
    systemctl restart tupoproxy-cover.service
    systemctl restart tupoproxy.service
    systemctl restart tupoproxy-edge.service
    sleep 2
    systemctl --quiet is-active tupoproxy-cover.service || die "tupoproxy cover service did not start"
    systemctl --quiet is-active tupoproxy.service || die "tupoproxy service did not start"
    systemctl --quiet is-active tupoproxy-edge.service || die "tupoproxy edge did not start"
    if [[ "$ACME_MODE" != "manual-dns" ]]; then
        systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    fi
fi

write_summary
