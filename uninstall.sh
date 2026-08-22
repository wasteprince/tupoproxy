#!/usr/bin/env bash
# Removes files and operating-system state created by the tupoproxy installer.
set -Eeuo pipefail
umask 027

readonly INSTALL_BINARY="/usr/local/bin/tupoproxy"
readonly CONFIG_DIR="/etc/tupoproxy"
readonly STATE_DIR="/var/lib/tupoproxy"
readonly COVER_DIR="/var/www/tupoproxy-cover"
readonly DNS_CREDENTIALS="/etc/letsencrypt/tupoproxy-dns.ini"
readonly RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/tupoproxy-nginx"
readonly SERVICES=(tupoproxy-edge.service tupoproxy.service tupoproxy-cover.service)

ASSUME_YES=0
PURGE_CERTIFICATE=0
DOMAIN=""
PUBLIC_PORT=""
CERTIFICATE_CHAIN=""
CERTIFICATE_MANAGED=""

usage() {
    cat <<'EOF'
Usage: sudo bash uninstall.sh [options]

Options:
  --yes                Do not ask for confirmation
  --purge-certificate  Also delete the Let's Encrypt certificate named after
                       the installed proxy domain
  -h, --help           Show this help

The script removes the tupoproxy services, binary, configuration, runtime
state, generated cover site, renewal hook, system user/group, and the proxy's
UFW rule. DNS credentials are removed together with an explicitly purged
certificate. Shared nginx, HAProxy, Certbot packages, port 80 rules,
certificates, and required renewal credentials are otherwise preserved.
EOF
}

die() {
    printf 'tupoproxy uninstaller: %s\n' "$*" >&2
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
    printf 'tupoproxy uninstaller: command failed at line %s (exit %s): %s\n' \
        "$line" "$status" "$command" >&2
    exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

while (($#)); do
    case "$1" in
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --purge-certificate)
            PURGE_CERTIFICATE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die "run this uninstaller as root (for example: sudo bash uninstall.sh)"

installation_value() {
    local label="$1"
    local summary_file="$CONFIG_DIR/INSTALLATION.txt"
    [[ -r "$summary_file" ]] || return 0
    sed -n "s/^${label}: //p" "$summary_file" | head -n 1
}

load_installation_metadata() {
    DOMAIN="$(installation_value Domain)"
    PUBLIC_PORT="$(installation_value 'Public port')"
    CERTIFICATE_CHAIN="$(installation_value 'Certificate chain')"
    CERTIFICATE_MANAGED="$(installation_value 'Certificate managed')"

    if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
        die "refusing to use invalid domain metadata from ${CONFIG_DIR}/INSTALLATION.txt"
    fi
    if [[ -n "$PUBLIC_PORT" ]]; then
        [[ "$PUBLIC_PORT" =~ ^[0-9]+$ ]] \
            || die "refusing to use invalid port metadata from ${CONFIG_DIR}/INSTALLATION.txt"
        ((PUBLIC_PORT >= 1 && PUBLIC_PORT <= 65535)) \
            || die "refusing to use out-of-range port metadata"
    fi
}

confirm_removal() {
    ((ASSUME_YES)) && return 0
    [[ -r /dev/tty ]] \
        || die "confirmation requires an interactive terminal; pass --yes for unattended removal"

    printf 'This will permanently remove tupoproxy configuration, secret, and state.\n' >/dev/tty
    if [[ -n "$DOMAIN" ]]; then
        printf 'Installed endpoint: %s:%s\n' "$DOMAIN" "${PUBLIC_PORT:-unknown}" >/dev/tty
    fi
    if ((PURGE_CERTIFICATE)); then
        printf 'The certificate for %s will also be deleted.\n' "${DOMAIN:-unknown}" >/dev/tty
    else
        printf 'The TLS certificate and shared system packages will be preserved.\n' >/dev/tty
    fi
    read -r -p 'Type DELETE to continue: ' confirmation </dev/tty
    [[ "$confirmation" == "DELETE" ]] || die "removal cancelled"
}

remove_managed_tree() {
    local target="$1"
    case "$target" in
        /etc/tupoproxy|/var/lib/tupoproxy|/var/www/tupoproxy-cover|/run/tupoproxy|/run/tupoproxy-cover|/run/tupoproxy-edge)
            [[ -e "$target" ]] || return 0
            rm -rf -- "$target"
            ;;
        *) die "refusing to remove unexpected path: $target" ;;
    esac
}

purge_certificate() {
    ((PURGE_CERTIFICATE)) || return 0
    [[ -n "$DOMAIN" ]] \
        || die "cannot purge a certificate because installation metadata has no domain"
    [[ "$CERTIFICATE_MANAGED" == "yes" ]] \
        || die "the installer did not record this certificate as managed; remove it manually"
    [[ "$CERTIFICATE_CHAIN" == "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] \
        || die "certificate was not managed under the expected Let's Encrypt path; remove it manually"
    command -v certbot >/dev/null 2>&1 \
        || die "certbot is required to purge the managed certificate"

    note "Deleting the explicitly requested Let's Encrypt certificate"
    certbot delete --non-interactive --cert-name "$DOMAIN"
    rm -f -- "$DNS_CREDENTIALS"
}

remove_firewall_rule() {
    [[ -n "$PUBLIC_PORT" ]] || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q '^Status: active' || return 0

    note "Removing the proxy's UFW rule for TCP/${PUBLIC_PORT}"
    ufw --force delete allow "${PUBLIC_PORT}/tcp" >/dev/null 2>&1 || true
}

load_installation_metadata
confirm_removal

note "Stopping and disabling tupoproxy services"
for service in "${SERVICES[@]}"; do
    systemctl disable --now "$service" >/dev/null 2>&1 || true
done
for service in "${SERVICES[@]}"; do
    systemctl --quiet is-active "$service" \
        && die "${service} is still active; stop it manually before removing data"
done

remove_firewall_rule
purge_certificate

note "Removing tupoproxy files and private data"
rm -f -- \
    "$INSTALL_BINARY" \
    "$RENEWAL_HOOK" \
    /etc/systemd/system/tupoproxy.service \
    /etc/systemd/system/tupoproxy-cover.service \
    /etc/systemd/system/tupoproxy-edge.service
remove_managed_tree "$CONFIG_DIR"
remove_managed_tree "$STATE_DIR"
remove_managed_tree "$COVER_DIR"
remove_managed_tree /run/tupoproxy
remove_managed_tree /run/tupoproxy-cover
remove_managed_tree /run/tupoproxy-edge

note "Removing the dedicated system account"
if getent passwd tupoproxy >/dev/null 2>&1; then
    userdel tupoproxy
fi
if getent group tupoproxy >/dev/null 2>&1; then
    groupdel tupoproxy
fi

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

printf '\n============================================================\n'
printf 'tupoproxy has been removed.\n'
if ((!PURGE_CERTIFICATE)) && [[ -n "$CERTIFICATE_CHAIN" ]]; then
    printf 'Preserved certificate: %s\n' "$CERTIFICATE_CHAIN"
fi
if ((!PURGE_CERTIFICATE)) && [[ -e "$DNS_CREDENTIALS" ]]; then
    printf 'Preserved renewal credentials: %s\n' "$DNS_CREDENTIALS"
fi
printf 'Preserved shared packages: nginx, HAProxy, Certbot, and their plugins.\n'
printf '============================================================\n'
