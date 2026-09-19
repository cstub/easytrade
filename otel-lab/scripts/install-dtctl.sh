#!/usr/bin/env bash
# Installs the pinned dtctl release for linux/amd64 to /usr/local/bin after SHA-256 verification.
set -euo pipefail
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LAB_DIR/versions.env"
V="$DTCTL_VERSION"; ARCH="$(uname -m)"; case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) echo "unsupported arch $ARCH" >&2; exit 2;; esac
T="$(mktemp -d)"; cd "$T"
curl -fsSL -o dtctl.tgz "https://github.com/dynatrace-oss/dtctl/releases/download/v$V/dtctl_${V}_linux_${A}.tar.gz"
curl -fsSL -o checksums.txt "https://github.com/dynatrace-oss/dtctl/releases/download/v$V/checksums.txt"
grep " dtctl_${V}_linux_${A}.tar.gz$" checksums.txt | sed 's#dtctl_.*#dtctl.tgz#' | sha256sum -c -
tar -xzf dtctl.tgz dtctl
install -m 0755 dtctl "${DTCTL_INSTALL_DIR:-/usr/local/bin}/dtctl"
cd /; rm -rf "$T"
dtctl version
