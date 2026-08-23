#!/usr/bin/env bash
# Automated Debian/Ubuntu installer for prebuilt tupoproxy releases.
set -Eeuo pipefail
umask 027

readonly REPOSITORY="wasteprince/tupoproxy"
readonly INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
readonly LIB_DIR="${LIB_DIR:-/usr/local/lib/tupoproxy}"
readonly CONFIG_DIR="${CONFIG_DIR:-/etc/tupoproxy}"
readonly STATE_DIR="${STATE_DIR:-/var/lib/tupoproxy}"
readonly EDGE_HELPER="${LIB_DIR}/edge-integration.py"
readonly MANAGED_CADDY_DIR="/opt/caddy"
readonly STARTUP_PROBE_TIMEOUT_SECONDS=60

DOMAIN=""
TLS_DOMAIN=""
TLS_DOMAIN_PORT="443"
EMAIL=""
PROFILE="chrome"
PROXY_USER="user"
readonly PUBLIC_PORT="443"
SECRET=""
AD_TAG=""
CERT_FULLCHAIN=""
CERT_KEY=""
TLS_CERT_FULLCHAIN=""
TLS_CERT_KEY=""
CERTIFICATE_PATHS_SET=0
CERTIFICATE_MANAGED=0
TLS_CERTIFICATE_PATHS_SET=0
TLS_CERTIFICATE_MANAGED=0
TLS_DECOY_SHARES_ADDRESS=0
TLS_DECOY_LOCAL=0
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
AD_TAG_CHANGED=0
INTERACTIVE_MODE=0
EDGE_MODE=""
EDGE_KIND=""
EDGE_TARGET=""
EDGE_RUNTIME_PORT=""
INTERNAL_LISTEN_IP="127.0.0.1"
PROXY_TRUSTED_CIDR="127.0.0.1/32"

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [options]

Required interactively or as flags:
  --domain NAME          Origin domain pointing to this server
  --tls-domain NAME      Separate HTTPS decoy encoded in the ee credential

Optional:
  --email ADDRESS        ACME e-mail for a same-server decoy certificate
  --profile NAME         chrome|firefox|compat|legacy (default: chrome)
  --user NAME            Credential label (default: user)
  --secret HEX           Existing 16-byte secret (default: generated)
  --ad-tag HEX           32-hex sponsored-channel tag from @MTProxybot
  --tls-cert-fullchain PATH
                         Existing PEM chain for a same-server TLS decoy
  --tls-cert-key PATH    Existing PEM key for a same-server TLS decoy
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
  sudo bash install.sh --domain proxy.example.com --tls-domain www.example.org \
    --email admin@example.com
  sudo bash install.sh --domain proxy.example.com --tls-domain www.example.org \
    --email admin@example.com \
    --acme-mode dns --dns-provider cloudflare \
    --dns-credentials /root/cloudflare.ini
  curl -fsSL https://github.com/wasteprince/tupoproxy/releases/latest/download/install.sh \
    | sudo bash -s -- --domain proxy.example.com --tls-domain www.example.org \
      --email admin@example.com
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
    local command="$2"
    command="${command%%$'\n'*}"
    if ((${#command} > 240)); then
        command="${command:0:237}..."
    fi
    printf 'tupoproxy installer: command failed at line %s (exit %s): %s\n' \
        "$line" "$status" "$command" >&2
    exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

if (($# == 0)); then
    INTERACTIVE_MODE=1
fi

while (($#)); do
    case "$1" in
        --domain)
            (($# >= 2)) || die "--domain requires a value"
            DOMAIN="$2"
            shift 2
            ;;
        --tls-domain)
            (($# >= 2)) || die "--tls-domain requires a value"
            TLS_DOMAIN="$2"
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
        --secret)
            (($# >= 2)) || die "--secret requires a value"
            SECRET="$2"
            shift 2
            ;;
        --ad-tag)
            (($# >= 2)) || die "--ad-tag requires a value"
            AD_TAG="$2"
            shift 2
            ;;
        --cert-fullchain)
            (($# >= 2)) || die "--cert-fullchain requires a value"
            CERT_FULLCHAIN="$2"
            CERTIFICATE_PATHS_SET=1
            shift 2
            ;;
        --cert-key)
            (($# >= 2)) || die "--cert-key requires a value"
            CERT_KEY="$2"
            CERTIFICATE_PATHS_SET=1
            shift 2
            ;;
        --tls-cert-fullchain)
            (($# >= 2)) || die "--tls-cert-fullchain requires a value"
            TLS_CERT_FULLCHAIN="$2"
            TLS_CERTIFICATE_PATHS_SET=1
            shift 2
            ;;
        --tls-cert-key)
            (($# >= 2)) || die "--tls-cert-key requires a value"
            TLS_CERT_KEY="$2"
            TLS_CERTIFICATE_PATHS_SET=1
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
        return 0
    fi
    [[ -r /dev/tty ]] || die "$prompt must be supplied as a command-line option"
    read -r -p "$prompt: " value </dev/tty
    printf -v "$variable_name" '%s' "$value"
    SETUP_WIZARD=1
}

prompt_setup_options() {
    local value
    [[ "$SETUP_WIZARD" == "1" ]] || return 0

    read -r -p "TLS fingerprint (chrome/firefox/compat/legacy) [chrome]: " value </dev/tty
    [[ -z "$value" ]] || PROFILE="${value,,}"

    read -r -p "Telegram credential user [user]: " value </dev/tty
    [[ -z "$value" ]] || PROXY_USER="$value"
}

installation_value() {
    local label="$1"
    local summary_file="$CONFIG_DIR/INSTALLATION.txt"
    [[ -r "$summary_file" ]] || return 0
    sed -n "s/^${label}: //p" "$summary_file" | head -n 1
}

load_existing_installation() {
    local saved_fullchain saved_key saved_value
    [[ -r "$CONFIG_DIR/INSTALLATION.txt" ]] || return 0

    [[ -n "$DOMAIN" ]] || DOMAIN="$(installation_value Domain)"
    [[ -n "$TLS_DOMAIN" ]] || TLS_DOMAIN="$(installation_value 'TLS decoy domain')"
    saved_value="$(installation_value 'TLS decoy port')"
    [[ -z "$saved_value" ]] || TLS_DOMAIN_PORT="$saved_value"
    [[ -n "$EMAIL" ]] || EMAIL="$(installation_value 'ACME e-mail')"
    [[ -n "$SECRET" ]] || SECRET="$(installation_value Secret)"
    [[ -n "$AD_TAG" ]] || AD_TAG="$(installation_value 'Advertising tag')"
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
    if ((!CERTIFICATE_PATHS_SET)); then
        saved_value="$(installation_value 'Certificate managed')"
        [[ "$saved_value" == "yes" ]] && CERTIFICATE_MANAGED=1
    fi
    if [[ -z "$TLS_CERT_FULLCHAIN" && -z "$TLS_CERT_KEY" ]]; then
        saved_fullchain="$(installation_value 'TLS decoy certificate chain')"
        saved_key="$(installation_value 'TLS decoy certificate key')"
        if [[ -r "$saved_fullchain" && -r "$saved_key" ]]; then
            TLS_CERT_FULLCHAIN="$saved_fullchain"
            TLS_CERT_KEY="$saved_key"
        fi
    fi
    if ((!TLS_CERTIFICATE_PATHS_SET)); then
        saved_value="$(installation_value 'TLS decoy certificate managed')"
        [[ "$saved_value" == "yes" ]] && TLS_CERTIFICATE_MANAGED=1
    fi
}

validate_domain() {
    [[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "invalid domain: $DOMAIN"
    DOMAIN="${DOMAIN,,}"
}

validate_tls_domain() {
    [[ "$TLS_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "invalid TLS decoy domain: $TLS_DOMAIN"
    TLS_DOMAIN="${TLS_DOMAIN,,}"
    [[ "$TLS_DOMAIN" != "$DOMAIN" ]] \
        || die "the TLS decoy domain must be different from the origin domain"
}

validate_tls_domain_port() {
    [[ "$TLS_DOMAIN_PORT" =~ ^[0-9]+$ ]] \
        || die "TLS decoy port must be numeric"
    ((TLS_DOMAIN_PORT >= 1 && TLS_DOMAIN_PORT <= 65535)) \
        || die "TLS decoy port must be between 1 and 65535"
}

validate_domain_routes() {
    local address
    local -a origin_addresses decoy_addresses

    mapfile -t origin_addresses < <(getent ahosts "$DOMAIN" | awk '{print $1}' | sort -u)
    ((${#origin_addresses[@]} > 0)) \
        || die "domain ${DOMAIN} does not resolve; create its DNS A/AAAA record first"
    mapfile -t decoy_addresses < <(getent ahosts "$TLS_DOMAIN" | awk '{print $1}' | sort -u)
    ((${#decoy_addresses[@]} > 0)) \
        || die "TLS decoy domain ${TLS_DOMAIN} does not resolve"

    for address in "${decoy_addresses[@]}"; do
        if printf '%s\n' "${origin_addresses[@]}" | grep -Fqx "$address"; then
            TLS_DECOY_SHARES_ADDRESS=1
            break
        fi
    done
}

tls_decoy_is_ready() {
    local tls_probe

    if ! tls_probe="$(timeout 15 openssl s_client \
        -connect "${TLS_DOMAIN}:${TLS_DOMAIN_PORT}" -servername "$TLS_DOMAIN" -alpn h2 \
        -verify_hostname "$TLS_DOMAIN" -verify_return_error -CApath /etc/ssl/certs \
        </dev/null 2>/dev/null)"; then
        return 1
    fi
    grep -Fq 'ALPN protocol: h2' <<<"$tls_probe"
}

detect_tls_decoy_mode() {
    note "Checking the FakeTLS decoy"
    if ((TLS_DECOY_SHARES_ADDRESS)); then
        TLS_DECOY_LOCAL=1
        note "The decoy shares this VPS; tupoproxy will keep its fallback on an isolated local port"
        return 0
    fi
    if tls_decoy_is_ready; then
        note "Using the existing HTTPS decoy at ${TLS_DOMAIN}:${TLS_DOMAIN_PORT}"
        TLS_DECOY_LOCAL=0
        return 0
    fi
    die "TLS decoy ${TLS_DOMAIN} must expose trusted HTTP/2 HTTPS on TCP/${TLS_DOMAIN_PORT}"
}

validate_ad_tag() {
    [[ -n "$AD_TAG" ]] || return 0
    [[ "$AD_TAG" =~ ^[A-Fa-f0-9]{32}$ ]] \
        || die "ad tag must be exactly 32 hex characters from @MTProxybot"
    [[ "${AD_TAG,,}" != "00000000000000000000000000000000" ]] \
        || die "an all-zero ad tag has no effect; use the tag issued by @MTProxybot"
    AD_TAG="${AD_TAG,,}"
}

validate_inputs() {
    case "$PROFILE" in
        chrome|firefox|compat|legacy) ;;
        *) die "profile must be chrome, firefox, compat, or legacy" ;;
    esac
    [[ "$PROXY_USER" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "invalid credential user label"
    if [[ -n "$SECRET" ]]; then
        [[ "$SECRET" =~ ^[A-Fa-f0-9]{32}$ ]] || die "secret must be exactly 32 hex characters"
        SECRET="${SECRET,,}"
    fi
    validate_ad_tag
    if [[ -n "$CERT_FULLCHAIN" || -n "$CERT_KEY" ]]; then
        [[ -n "$CERT_FULLCHAIN" && -n "$CERT_KEY" ]] \
            || die "--cert-fullchain and --cert-key must be provided together"
        [[ "$CERT_FULLCHAIN" =~ ^/[A-Za-z0-9_./-]+$ && "$CERT_KEY" =~ ^/[A-Za-z0-9_./-]+$ ]] \
            || die "certificate paths must be absolute and contain only letters, digits, '_', '-', '.', and '/'"
        [[ -r "$CERT_FULLCHAIN" && -r "$CERT_KEY" ]] || die "provided certificate files are not readable"
    fi
    if [[ -n "$TLS_CERT_FULLCHAIN" || -n "$TLS_CERT_KEY" ]]; then
        if ((!TLS_DECOY_LOCAL)); then
            ((!TLS_CERTIFICATE_PATHS_SET)) \
                || die "--tls-cert-fullchain and --tls-cert-key are only used for a same-server decoy"
        else
            [[ -n "$TLS_CERT_FULLCHAIN" && -n "$TLS_CERT_KEY" ]] \
                || die "--tls-cert-fullchain and --tls-cert-key must be provided together"
            [[ "$TLS_CERT_FULLCHAIN" =~ ^/[A-Za-z0-9_./-]+$ && "$TLS_CERT_KEY" =~ ^/[A-Za-z0-9_./-]+$ ]] \
                || die "TLS decoy certificate paths must be safe absolute paths"
            [[ -r "$TLS_CERT_FULLCHAIN" && -r "$TLS_CERT_KEY" ]] \
                || die "provided TLS decoy certificate files are not readable"
        fi
    fi
    if [[ "$TLS_DECOY_LOCAL" == "1" && -z "$TLS_CERT_FULLCHAIN" ]]; then
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
    if [[ "$ACME_MODE" == "existing" \
        && "$TLS_DECOY_LOCAL" == "1" && -z "$TLS_CERT_FULLCHAIN" ]]; then
        die "ACME mode existing requires certificate paths for the local decoy"
    fi
    if [[ "$ACME_MODE" == "webroot" ]]; then
        [[ "$ACME_WEBROOT" =~ ^/[A-Za-z0-9_./-]+$ && -d "$ACME_WEBROOT" ]] \
            || die "--acme-webroot must point to an existing absolute directory"
    fi
}

validate_existing_certificates() {
    if [[ -n "$CERT_FULLCHAIN" ]]; then
        openssl x509 -in "$CERT_FULLCHAIN" -noout -checkhost "$DOMAIN" >/dev/null \
            || die "the origin certificate does not cover ${DOMAIN}"
    fi
    if ((TLS_DECOY_LOCAL)) && [[ -n "$TLS_CERT_FULLCHAIN" ]]; then
        openssl x509 -in "$TLS_CERT_FULLCHAIN" -noout -checkhost "$TLS_DOMAIN" >/dev/null \
            || die "the TLS decoy certificate does not cover ${TLS_DOMAIN}"
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
    local machine target asset release_base checksum_line helper_checksum_line
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
    if ((!BINARY_ONLY)); then
        download_file "${release_base}/edge-integration.py" \
            "${INSTALL_TEMP_DIR}/edge-integration.py"
    fi

    checksum_line="$(grep -E "^[0-9a-f]{64}  ${asset}$" "${INSTALL_TEMP_DIR}/CHECKSUMS.txt" || true)"
    [[ -n "$checksum_line" ]] || die "release checksum for ${asset} is missing"
    printf '%s\n' "$checksum_line" >"${INSTALL_TEMP_DIR}/asset.sha256"
    (cd "$INSTALL_TEMP_DIR" && sha256sum --check asset.sha256)
    if ((!BINARY_ONLY)); then
        helper_checksum_line="$(grep -E '^[0-9a-f]{64}  edge-integration\.py$' \
            "${INSTALL_TEMP_DIR}/CHECKSUMS.txt" || true)"
        [[ -n "$helper_checksum_line" ]] \
            || die "release checksum for edge-integration.py is missing"
        printf '%s\n' "$helper_checksum_line" >"${INSTALL_TEMP_DIR}/helper.sha256"
        (cd "$INSTALL_TEMP_DIR" && sha256sum --check helper.sha256)
    fi

    mkdir -p "${INSTALL_TEMP_DIR}/unpack"
    tar -xzf "${INSTALL_TEMP_DIR}/${asset}" -C "${INSTALL_TEMP_DIR}/unpack"
    [[ -f "${INSTALL_TEMP_DIR}/unpack/tupoproxy" ]] || die "release archive has no tupoproxy binary"

    install -d -m 0755 "$INSTALL_DIR"
    install -m 0755 "${INSTALL_TEMP_DIR}/unpack/tupoproxy" "$INSTALL_DIR/tupoproxy"
    if ((!BINARY_ONLY)); then
        install -d -m 0755 "$LIB_DIR"
        install -m 0755 "${INSTALL_TEMP_DIR}/edge-integration.py" "$EDGE_HELPER"
        python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
            "$EDGE_HELPER"
    fi
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

choose_local_decoy_port() {
    local candidate
    ((TLS_DECOY_LOCAL)) || return 0
    [[ "$TLS_DOMAIN_PORT" == "$PUBLIC_PORT" ]] || return 0

    for candidate in 3443 4443 5443 6443; do
        if ! port_is_listening "$candidate"; then
            TLS_DOMAIN_PORT="$candidate"
            note "The public edge uses TCP/${PUBLIC_PORT}; selected isolated decoy port ${candidate}"
            return 0
        fi
    done
    die "no isolated local port is free for the same-server FakeTLS decoy"
}

ensure_internal_ports_are_safe() {
    local proxy_port=18443 api_port=9091
    systemctl stop tupoproxy.service tupoproxy-cover.service 2>/dev/null || true
    if port_is_listening "$proxy_port"; then
        die "internal port ${proxy_port} is already in use"
    fi
    if port_is_listening "$api_port"; then
        die "local API port ${api_port} is already in use"
    fi
    if ((TLS_DECOY_LOCAL)); then
        if port_is_listening "$TLS_DOMAIN_PORT"; then
            die "same-server TLS decoy port ${TLS_DOMAIN_PORT} is already in use; choose another one"
        fi
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
            return 0
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
    if ((!TLS_DECOY_LOCAL)) || [[ -n "$TLS_CERT_FULLCHAIN" ]]; then
        ACME_MODE="existing"
        return 0
    fi

    if [[ "$ACME_MODE" == "dns" ]]; then
        prompt_dns_settings
        return 0
    fi
    [[ "$ACME_MODE" == "auto" ]] || return 0

    if [[ -n "$DNS_PROVIDER" ]]; then
        ACME_MODE="dns"
        prompt_dns_settings
        return 0
    fi
    if ! port_is_listening 80; then
        ACME_MODE="standalone"
        return 0
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

prepare_dns_credentials() {
    local managed_credentials="/etc/letsencrypt/tupoproxy-dns.ini"
    [[ "$ACME_MODE" == "dns" ]] || return 0

    install -d -m 0700 /etc/letsencrypt
    if [[ "$DNS_PROVIDER" == "cloudflare" && -n "$CLOUDFLARE_API_TOKEN" ]]; then
        printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" >"$managed_credentials"
        chmod 0600 "$managed_credentials"
        DNS_CREDENTIALS="$managed_credentials"
    elif [[ -n "$DNS_CREDENTIALS" && "$DNS_CREDENTIALS" != "$managed_credentials" ]]; then
        install -m 0600 "$DNS_CREDENTIALS" "$managed_credentials"
        DNS_CREDENTIALS="$managed_credentials"
    fi
}

request_certificate() {
    local cert_domain="$1"
    local dns_option
    local -a certbot_args

    certbot_args=(
        certonly --agree-tos --keep-until-expiring --email "$EMAIL"
        --cert-name "$cert_domain" -d "$cert_domain"
    )
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
            dns_option="--dns-${DNS_PROVIDER}"
            certbot_args+=(--non-interactive "$dns_option")
            if [[ "$DNS_PROVIDER" != "route53" ]]; then
                [[ -n "$DNS_CREDENTIALS" ]] \
                    || die "DNS credentials are required for provider ${DNS_PROVIDER}"
                certbot_args+=(
                    "${dns_option}-propagation-seconds" "$DNS_PROPAGATION_SECONDS"
                    "${dns_option}-credentials" "$DNS_CREDENTIALS"
                )
            fi
            certbot "${certbot_args[@]}"
            ;;
        manual-dns)
            [[ -r /dev/tty ]] || die "manual DNS validation requires an interactive terminal"
            note "Certbot will show a TXT record for ${cert_domain}; add it in your DNS panel and continue"
            certbot "${certbot_args[@]}" --manual --preferred-challenges dns </dev/tty
            ;;
        *) die "internal error: unresolved ACME mode ${ACME_MODE}" ;;
    esac
}

configure_acme() {
    prepare_dns_credentials

    if ((TLS_DECOY_LOCAL)) && [[ -z "$TLS_CERT_FULLCHAIN" ]]; then
        request_certificate "$TLS_DOMAIN"
        TLS_CERT_FULLCHAIN="/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem"
        TLS_CERT_KEY="/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem"
        TLS_CERTIFICATE_MANAGED=1
    fi
    if ((TLS_DECOY_LOCAL)); then
        [[ -r "$TLS_CERT_FULLCHAIN" && -r "$TLS_CERT_KEY" ]] \
            || die "TLS decoy certificate issuance did not produce readable files"
    fi
}

configure_cover_site() {
    local cover_root="/var/www/tupoproxy-cover"
    local seed_file="$CONFIG_DIR/cover-site.seed"
    local site_seed theme_index accent page_background panel_background heading copy decoy_server

    install -d -m 0750 "$CONFIG_DIR"
    install -d -m 0755 /run/tupoproxy-cover
    install -d -o root -g www-data -m 0755 "$cover_root"

    site_seed=""
    if [[ -r "$seed_file" ]]; then
        site_seed="$(head -n 1 "$seed_file")"
    fi
    if [[ ! "$site_seed" =~ ^[a-f0-9]{32}$ ]]; then
        site_seed="$(openssl rand -hex 16)"
        printf '%s\n' "$site_seed" >"$seed_file"
        chmod 0640 "$seed_file"
    fi

    theme_index=$((16#${site_seed:0:2} % 4))
    case "$theme_index" in
        0)
            accent="#3157d5"
            page_background="#f4f6fb"
            panel_background="#ffffff"
            heading="A quiet place on the web"
            copy="This website is online and ready for its next chapter."
            ;;
        1)
            accent="#087f5b"
            page_background="#f0f7f4"
            panel_background="#fbfefd"
            heading="Everything is up and running"
            copy="Thanks for stopping by. New content will be published here soon."
            ;;
        2)
            accent="#9c4d14"
            page_background="#faf5ef"
            panel_background="#fffdf9"
            heading="Welcome to our new home"
            copy="The site is available while we prepare the next update."
            ;;
        *)
            accent="#6b46b5"
            page_background="#f6f3fa"
            panel_background="#fefcff"
            heading="This domain is active"
            copy="A new website is being prepared. Please check back later."
            ;;
    esac

    cat >"$cover_root/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${DOMAIN}</title>
    <link rel="stylesheet" href="/site-${site_seed:0:8}.css">
</head>
<body>
    <main>
        <p class="domain">${DOMAIN}</p>
        <h1>${heading}</h1>
        <p class="copy">${copy}</p>
    </main>
</body>
</html>
EOF
    cat >"$cover_root/decoy.html" <<EOF
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${TLS_DOMAIN}</title>
    <link rel="stylesheet" href="/site-${site_seed:0:8}.css">
</head>
<body>
    <main>
        <p class="domain">${TLS_DOMAIN}</p>
        <h1>${heading}</h1>
        <p class="copy">${copy}</p>
    </main>
</body>
</html>
EOF
    cat >"$cover_root/site-${site_seed:0:8}.css" <<EOF
:root { color-scheme: light; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; color: #20242c; background: ${page_background}; }
main { width: min(42rem, calc(100% - 2rem)); padding: clamp(2rem, 7vw, 5rem); border: 1px solid #00000014; border-radius: 1.25rem; background: ${panel_background}; box-shadow: 0 1.5rem 4rem #18203012; }
.domain { margin: 0 0 1rem; color: ${accent}; font-size: .88rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
h1 { max-width: 14ch; margin: 0; font-size: clamp(2.25rem, 8vw, 4.8rem); line-height: .98; letter-spacing: -.045em; }
.copy { max-width: 34rem; margin: 1.5rem 0 0; color: #59616f; font-size: 1.08rem; line-height: 1.65; }
EOF
    cat >"$cover_root/robots.txt" <<'EOF'
User-agent: *
Allow: /
EOF
    chmod 0644 "$cover_root/index.html" "$cover_root/decoy.html" \
        "$cover_root/site-${site_seed:0:8}.css" "$cover_root/robots.txt"

    decoy_server=""
    if ((TLS_DECOY_LOCAL)); then
        decoy_server="$(cat <<EOF

    server {
        listen 127.0.0.1:${TLS_DOMAIN_PORT} ssl http2;
        server_name ${TLS_DOMAIN};

        ssl_certificate "${TLS_CERT_FULLCHAIN}";
        ssl_certificate_key "${TLS_CERT_KEY}";
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:TUPOPROXY_DECOY:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets on;

        add_header X-Content-Type-Options "nosniff" always;
        root "${cover_root}";

        location = / {
            try_files /decoy.html =404;
        }

        location / {
            try_files \$uri =404;
        }
    }
EOF
)"
    fi

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
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    etag on;

${decoy_server}
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
    local ad_tag_line=""
    local mask_host_line=""
    local trusted_cidrs='"127.0.0.1/32", "::1/128"'
    [[ -n "$SECRET" ]] || SECRET="$(openssl rand -hex 16)"
    if [[ -n "$AD_TAG" ]]; then
        ad_tag_line="ad_tag = \"${AD_TAG}\""
    fi
    if ((TLS_DECOY_LOCAL)); then
        mask_host_line="mask_host = \"127.0.0.1\""
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
public_host = "${DOMAIN}"
public_port = ${PUBLIC_PORT}

[server]
proxy_protocol = true
proxy_protocol_trusted_cidrs = [${trusted_cidrs}]

[[server.listeners]]
ip = "${INTERNAL_LISTEN_IP}"
port = 18443
announce = "${DOMAIN}"

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]

[censorship]
tls_domain = "${TLS_DOMAIN}"
tls_fingerprints = { "${TLS_DOMAIN}" = "${PROFILE}" }
mask = true
mask_dynamic = true
${mask_host_line}
mask_port = ${TLS_DOMAIN_PORT}
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
    systemctl disable --now tupoproxy-edge.service >/dev/null 2>&1 || true
    rm -f -- "$CONFIG_DIR/haproxy.cfg" /etc/systemd/system/tupoproxy-edge.service
    systemctl daemon-reload
    systemctl enable tupoproxy-cover.service tupoproxy.service
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
        case "$ACME_MODE" in
            standalone|nginx|apache|webroot) ufw allow 80/tcp ;;
        esac
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
    local service

    for service in tupoproxy-cover.service tupoproxy.service; do
        printf '\n----- %s status -----\n' "$service" >&2
        systemctl --no-pager --full status "$service" >&2 || true
        printf '\n----- %s recent journal -----\n' "$service" >&2
        journalctl --no-pager --full -n 40 -u "$service" >&2 || true
    done
    if [[ "$EDGE_MODE" == "managed" ]]; then
        printf '\n----- tupoproxy-caddy logs -----\n' >&2
        docker logs --tail 80 tupoproxy-caddy >&2 || true
    else
        printf '\n----- reverse-proxy integration -----\n' >&2
        sed -n '1,200p' "$STATE_DIR/edge-integration.json" >&2 || true
    fi
}

probe_tls_endpoint() {
    local connect_address="$1"
    local server_name="$2"
    local tls_probe

    if ! tls_probe="$(timeout 15 openssl s_client \
        -connect "$connect_address" -servername "$server_name" -alpn h2 \
        -verify_hostname "$server_name" -verify_return_error -CApath /etc/ssl/certs \
        </dev/null 2>&1)"; then
        printf '%s\n' "$tls_probe"
        return 1
    fi
    if ! grep -Fq 'ALPN protocol: h2' <<<"$tls_probe"; then
        printf '%s\n' "$tls_probe"
        return 1
    fi
}

wait_for_tls_endpoint() {
    local label="$1"
    local connect_address="$2"
    local server_name="$3"
    local deadline=$((SECONDS + STARTUP_PROBE_TIMEOUT_SECONDS))
    local last_probe=""
    local waiting=0

    while true; do
        if last_probe="$(probe_tls_endpoint "$connect_address" "$server_name")"; then
            return 0
        fi
        if ((SECONDS >= deadline)); then
            printf 'TLS readiness check timed out for %s. Last probe output:\n' "$label" >&2
            printf '%s\n' "$last_probe" | tail -n 40 >&2
            return 1
        fi
        if ((!waiting)); then
            printf 'Waiting up to %s seconds for %s to become ready\n' \
                "$STARTUP_PROBE_TIMEOUT_SECONDS" "$label"
            waiting=1
        fi
        sleep 2
    done
}

wait_for_public_cover() {
    local deadline=$((SECONDS + STARTUP_PROBE_TIMEOUT_SECONDS))
    local cover_body=""
    local waiting=0

    while true; do
        if cover_body="$(curl --fail --silent --show-error --insecure --noproxy '*' \
            --connect-timeout 5 --max-time 15 \
            "https://${DOMAIN}:${PUBLIC_PORT}/" 2>&1)" \
            && [[ "$cover_body" == *"${DOMAIN}"* ]]; then
            return 0
        fi
        if ((SECONDS >= deadline)); then
            printf 'HTTPS cover readiness check timed out. Last response:\n%s\n' \
                "$cover_body" >&2
            return 1
        fi
        if ((!waiting)); then
            printf 'Waiting up to %s seconds for the public HTTPS cover to become ready\n' \
                "$STARTUP_PROBE_TIMEOUT_SECONDS"
            waiting=1
        fi
        sleep 2
    done
}

fail_public_verification() {
    local message="$1"
    print_startup_diagnostics
    if "$EDGE_HELPER" remove --state-dir "$STATE_DIR"; then
        die "$message; the reverse-proxy change was rolled back"
    fi
    die "$message; automatic reverse-proxy rollback also failed, inspect the diagnostics above"
}

verify_public_cover() {
    note "Verifying the public HTTPS camouflage path"

    if ((TLS_DECOY_LOCAL)); then
        if ! wait_for_tls_endpoint \
            "same-server TLS decoy on TCP/${TLS_DOMAIN_PORT}" \
            "127.0.0.1:${TLS_DOMAIN_PORT}" "$TLS_DOMAIN"; then
            fail_public_verification \
                "same-server TLS decoy failed on isolated TCP/${TLS_DOMAIN_PORT}"
        fi
    fi

    if ! wait_for_tls_endpoint \
        "public origin ${DOMAIN}:${PUBLIC_PORT}" \
        "${DOMAIN}:${PUBLIC_PORT}" "$DOMAIN"; then
        fail_public_verification "public TLS probe failed for ${DOMAIN}:${PUBLIC_PORT}"
    fi
    if [[ "$EDGE_MODE" == "managed" ]]; then
        if ! wait_for_public_cover; then
            fail_public_verification \
                "public HTTPS cover check failed for ${DOMAIN}:${PUBLIC_PORT}"
        fi
    fi
    if ! wait_for_tls_endpoint \
        "FakeTLS decoy ${TLS_DOMAIN} through TCP/${PUBLIC_PORT}" \
        "${DOMAIN}:${PUBLIC_PORT}" "$TLS_DOMAIN"; then
        fail_public_verification \
            "FakeTLS decoy fallback failed for ${TLS_DOMAIN} through the public port"
    fi
}

prompt_bot_registration() {
    local value
    if [[ -n "$AD_TAG" || ("$SETUP_WIZARD" != "1" && "$INTERACTIVE_MODE" != "1") ]]; then
        return 0
    fi

    printf '\n============================================================\n' >/dev/tty
    printf '@MTProxybot registration\n' >/dev/tty
    printf 'Proxy address for the bot (host:port): %s:%s\n' "$DOMAIN" "$PUBLIC_PORT" >/dev/tty
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
    AD_TAG_CHANGED=1
}

telegram_proxy_link() {
    local domain_hex
    domain_hex="$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')"
    printf 'tg://proxy?server=%s&port=%s&secret=ee%s%s' \
        "$DOMAIN" "$PUBLIC_PORT" "$SECRET" "$domain_hex"
}

save_summary() {
    local telegram_link
    telegram_link="$(telegram_proxy_link)"
    cat > "$CONFIG_DIR/INSTALLATION.txt" <<EOF
tupoproxy installation
Domain: ${DOMAIN}
TLS decoy domain: ${TLS_DOMAIN}
TLS decoy port: ${TLS_DOMAIN_PORT}
TLS decoy local: $([[ "$TLS_DECOY_LOCAL" == "1" ]] && printf 'yes' || printf 'no')
ACME e-mail: ${EMAIL}
Public port: ${PUBLIC_PORT}
Edge mode: ${EDGE_MODE}
Edge kind: ${EDGE_KIND}
Edge target: ${EDGE_TARGET}
Edge runtime port: ${EDGE_RUNTIME_PORT}
TLS profile: ${PROFILE}
Credential user: ${PROXY_USER}
Secret: ${SECRET}
Advertising tag: ${AD_TAG}
Certificate chain: ${CERT_FULLCHAIN}
Certificate key: ${CERT_KEY}
Certificate managed: $([[ "$CERTIFICATE_MANAGED" == "1" ]] && printf 'yes' || printf 'no')
TLS decoy certificate chain: ${TLS_CERT_FULLCHAIN}
TLS decoy certificate key: ${TLS_CERT_KEY}
TLS decoy certificate managed: $([[ "$TLS_CERTIFICATE_MANAGED" == "1" ]] && printf 'yes' || printf 'no')

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
    printf 'Public endpoint: %s:%s\n' "$DOMAIN" "$PUBLIC_PORT"
    printf 'Reverse proxy: %s (%s, %s)\n' "$EDGE_KIND" "$EDGE_MODE" "$EDGE_TARGET"
    printf 'FakeTLS decoy SNI: %s\n' "$TLS_DOMAIN"
    printf 'FakeTLS decoy HTTPS port: %s\n' "$TLS_DOMAIN_PORT"
    if ((TLS_DECOY_LOCAL)); then
        printf 'FakeTLS decoy mode: isolated on this VPS\n'
    else
        printf 'FakeTLS decoy mode: existing external HTTPS site\n'
    fi
    printf 'TLS profile: %s\n' "$PROFILE"
    if [[ -n "$AD_TAG" ]]; then
        printf 'Sponsored-channel tag: configured\n'
    fi
    printf 'Certificate mode: %s\n' "$ACME_MODE"
    printf 'When @MTProxybot says "Now please specify its secret in hex format.", send:\n'
    printf '%s\n' "$SECRET"
    printf '(32 hex characters; without ee or the domain)\n'
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
    prompt_value TLS_DOMAIN "Separate FakeTLS decoy domain"
    validate_tls_domain
    validate_domain_routes
    validate_tls_domain_port
    prompt_setup_options
fi

note "Installing operating-system dependencies"
if ((BINARY_ONLY)); then
    apt_install ca-certificates curl tar coreutils
else
    package_is_installed nginx && NGINX_WAS_INSTALLED=1
    apt_install \
        ca-certificates curl tar coreutils openssl iproute2 nginx certbot python3
    if ((!NGINX_WAS_INSTALLED)); then
        systemctl disable --now nginx.service >/dev/null 2>&1 || true
    fi
fi

if ((!BINARY_ONLY)); then
    detect_tls_decoy_mode
fi

note "Installing the prebuilt static binary"
install_prebuilt_binary

if ((BINARY_ONLY)); then
    note "Binary-only installation complete"
    exit 0
fi

configure_reverse_proxy_mode
choose_local_decoy_port
if ((TLS_DECOY_LOCAL)) && [[ -z "$TLS_CERT_FULLCHAIN" ]]; then
    prompt_value EMAIL "ACME e-mail"
fi
validate_inputs
validate_existing_certificates
ensure_internal_ports_are_safe
choose_acme_mode
validate_inputs
install_acme_plugin

note "Preparing certificate and HTTPS cover"
configure_acme
validate_existing_certificates
configure_cover_site

note "Writing tupoproxy and edge configurations"
configure_proxy
configure_services
open_firewall_ports
save_summary

if ((NO_START)); then
    note "Configuration complete; services were not started (--no-start)"
else
    note "Starting tupoproxy"
    restart_service_or_die tupoproxy-cover.service
    restart_service_or_die tupoproxy.service
    systemctl --quiet is-active tupoproxy-cover.service || die "tupoproxy cover service did not start"
    systemctl --quiet is-active tupoproxy.service || die "tupoproxy service did not start"
    note "Adding the raw FakeTLS route to the reverse proxy"
    configure_public_edge
    verify_public_cover
    if [[ "$ACME_MODE" != "manual-dns" ]]; then
        systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    fi
fi

prompt_bot_registration
if ((AD_TAG_CHANGED)); then
    note "Applying the advertising tag from @MTProxybot"
    configure_proxy
    if ((!NO_START)); then
        restart_service_or_die tupoproxy.service
        systemctl --quiet is-active tupoproxy.service \
            || die "tupoproxy service did not restart after applying the advertising tag"
    fi
fi

write_summary
