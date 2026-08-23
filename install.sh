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
readonly FAKETLS_PROBE="${LIB_DIR}/fake-tls-probe.py"
readonly INSTALL_RUNTIME="${LIB_DIR}/install-runtime.sh"
readonly MANAGED_CADDY_DIR="/opt/caddy"

DOMAIN=""
TLS_DOMAIN=""
PUBLIC_HOST=""
PROFILE="chrome"
PROXY_USER="user"
readonly PUBLIC_PORT="443"
SECRET=""
AD_TAG=""
NO_START=0
BINARY_ONLY=0
INSTALL_TEMP_DIR=""
CREATED_POLICY_RC_D=0
APT_UPDATED=0
SETUP_WIZARD=0
PROFILE_SET=0
PROXY_USER_SET=0
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
  --domain NAME          Existing HTTPS domain handled by the reverse proxy
  --tls-domain NAME      Dedicated hostname encoded as the FakeTLS SNI

Optional:
  --profile NAME         chrome|firefox|compat|legacy (default: chrome)
  --user NAME            Credential label (default: user)
  --secret HEX           Existing 16-byte secret (default: generated)
  --ad-tag HEX           32-hex sponsored-channel tag from @MTProxybot
  --binary-only          Install the prebuilt binary without server setup
  --no-start             Write configuration without starting services
  -h, --help             Show this help

Examples:
  sudo bash install.sh --domain site.example.com --tls-domain proxy.example.com
  curl -fsSL https://github.com/wasteprince/tupoproxy/releases/latest/download/install.sh \
    | sudo bash -s -- --domain site.example.com --tls-domain proxy.example.com
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
    local saved_value
    [[ -r "$CONFIG_DIR/INSTALLATION.txt" ]] || return 0

    [[ -n "$DOMAIN" ]] || DOMAIN="$(installation_value Domain)"
    [[ -n "$TLS_DOMAIN" ]] || TLS_DOMAIN="$(installation_value 'TLS decoy domain')"
    [[ -n "$PUBLIC_HOST" ]] || PUBLIC_HOST="$(installation_value 'Public host')"
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

validate_domain_routes() {
    local -a origin_addresses decoy_addresses

    mapfile -t origin_addresses < <(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
    ((${#origin_addresses[@]} == 1)) \
        || die "origin domain ${DOMAIN} must have exactly one direct IPv4 A record"
    mapfile -t decoy_addresses < <(getent ahostsv4 "$TLS_DOMAIN" | awk '{print $1}' | sort -u)
    ((${#decoy_addresses[@]} > 0)) \
        || die "FakeTLS domain ${TLS_DOMAIN} has no IPv4 A record"
    PUBLIC_HOST="$DOMAIN"
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
    local probe_checksum_line runtime_checksum_line
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
        download_file "${release_base}/fake-tls-probe.py" \
            "${INSTALL_TEMP_DIR}/fake-tls-probe.py"
        download_file "${release_base}/install-runtime.sh" \
            "${INSTALL_TEMP_DIR}/install-runtime.sh"
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
        probe_checksum_line="$(grep -E '^[0-9a-f]{64}  fake-tls-probe\.py$' \
            "${INSTALL_TEMP_DIR}/CHECKSUMS.txt" || true)"
        [[ -n "$probe_checksum_line" ]] \
            || die "release checksum for fake-tls-probe.py is missing"
        printf '%s\n' "$probe_checksum_line" >"${INSTALL_TEMP_DIR}/probe.sha256"
        (cd "$INSTALL_TEMP_DIR" && sha256sum --check probe.sha256)
        runtime_checksum_line="$(grep -E '^[0-9a-f]{64}  install-runtime\.sh$' \
            "${INSTALL_TEMP_DIR}/CHECKSUMS.txt" || true)"
        [[ -n "$runtime_checksum_line" ]] \
            || die "release checksum for install-runtime.sh is missing"
        printf '%s\n' "$runtime_checksum_line" >"${INSTALL_TEMP_DIR}/runtime.sha256"
        (cd "$INSTALL_TEMP_DIR" && sha256sum --check runtime.sha256)
    fi

    mkdir -p "${INSTALL_TEMP_DIR}/unpack"
    tar -xzf "${INSTALL_TEMP_DIR}/${asset}" -C "${INSTALL_TEMP_DIR}/unpack"
    [[ -f "${INSTALL_TEMP_DIR}/unpack/tupoproxy" ]] || die "release archive has no tupoproxy binary"

    install -d -m 0755 "$INSTALL_DIR"
    install -m 0755 "${INSTALL_TEMP_DIR}/unpack/tupoproxy" "$INSTALL_DIR/tupoproxy"
    if ((!BINARY_ONLY)); then
        install -d -m 0755 "$LIB_DIR"
        install -m 0755 "${INSTALL_TEMP_DIR}/edge-integration.py" "$EDGE_HELPER"
        install -m 0755 "${INSTALL_TEMP_DIR}/fake-tls-probe.py" "$FAKETLS_PROBE"
        install -m 0644 "${INSTALL_TEMP_DIR}/install-runtime.sh" "$INSTALL_RUNTIME"
        python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
            "$EDGE_HELPER"
        python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
            "$FAKETLS_PROBE"
        bash -n "$INSTALL_RUNTIME"
    fi
    "$INSTALL_DIR/tupoproxy" --version
    rm -rf -- "$INSTALL_TEMP_DIR"
    INSTALL_TEMP_DIR=""
}

export DEBIAN_FRONTEND=noninteractive

if ((!BINARY_ONLY)); then
    note "Starting automated tupoproxy setup"
    load_existing_installation
    prompt_value DOMAIN "Existing HTTPS domain on this reverse proxy"
    validate_domain
    prompt_value TLS_DOMAIN "Dedicated FakeTLS proxy domain"
    validate_tls_domain
    validate_domain_routes
    prompt_setup_options
fi

note "Installing operating-system dependencies"
if ((BINARY_ONLY)); then
    apt_install ca-certificates curl tar coreutils
else
    apt_install \
        ca-certificates curl tar coreutils openssl iproute2 python3
fi

note "Installing the prebuilt static binary"
install_prebuilt_binary

if ((BINARY_ONLY)); then
    note "Binary-only installation complete"
    exit 0
fi

# shellcheck source=install-runtime.sh
source "$INSTALL_RUNTIME"

configure_reverse_proxy_mode
validate_inputs
ensure_internal_ports_are_safe

note "Writing tupoproxy and edge configurations"
configure_proxy
configure_services
open_firewall_ports
save_summary

if ((NO_START)); then
    note "Configuration complete; services were not started (--no-start)"
else
    note "Starting tupoproxy"
    restart_service_or_die tupoproxy.service
    systemctl --quiet is-active tupoproxy.service || die "tupoproxy service did not start"
    note "Adding the raw FakeTLS route to the reverse proxy"
    configure_public_edge
    verify_fake_tls_route
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
