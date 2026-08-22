#!/bin/sh
# Install the binary built from this checkout. Configuration is intentionally
# separate because public 443/ACME layouts depend on the host web stack.
set -eu

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR=${INSTALL_DIR:-/usr/local/bin}

command -v cargo >/dev/null 2>&1 || {
    echo "cargo is required; install the stable Rust toolchain first" >&2
    exit 1
}
command -v install >/dev/null 2>&1 || {
    echo "install(1) is required" >&2
    exit 1
}

if [ "$(id -u)" -eq 0 ]; then
    RUN_ROOT=
elif command -v sudo >/dev/null 2>&1; then
    RUN_ROOT=sudo
else
    echo "Run as root or install sudo" >&2
    exit 1
fi

cd "$SOURCE_DIR"
cargo build --release --locked --bin tupoproxy
$RUN_ROOT install -d -m 0755 "$INSTALL_DIR"
$RUN_ROOT install -m 0755 target/release/tupoproxy "$INSTALL_DIR/tupoproxy"

echo "Installed $INSTALL_DIR/tupoproxy"
echo "Continue with deploy/README.md to configure HTTPS/ACME coexistence."
