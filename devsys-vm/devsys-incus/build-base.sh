#!/usr/bin/env bash
# build-base.sh — generalize a devsys base VM and publish it as a golden image.
# Run on the Incus HOST (beehive), after you've installed the toolchain into
# the base VM (see README) and BEFORE any Tailscale login.
#
#   ./build-base.sh [base-instance] [image-alias]
#   ./build-base.sh devsys-base devsys-base
#
# "Generalize" is mandatory: without it every clone shares the base's machine-id,
# SSH host keys, and Tailscale identity, and they collide on the tailnet.
set -euo pipefail
BASE=${1:-devsys-base}
ALIAS=${2:-devsys-base}

incus info "$BASE" >/dev/null 2>&1 || { echo "No such instance: $BASE" >&2; exit 1; }

echo "▸ Generalizing $BASE (clearing per-machine identity)…"
incus exec "$BASE" -- bash -euc '
  systemctl stop tailscaled 2>/dev/null || true
  rm -f /var/lib/tailscale/tailscaled.state
  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_*
  cloud-init clean --logs 2>/dev/null || true
  rm -f /root/.bash_history
  apt-get clean 2>/dev/null || true
'

echo "▸ Stopping $BASE…"
incus stop "$BASE"

echo "▸ Publishing image alias '$ALIAS'…"
incus image delete "$ALIAS" 2>/dev/null || true
incus publish "$BASE" --alias "$ALIAS" --compression zstd

echo "✔ Published golden image '$ALIAS'."
echo "  Clone a dev VM with:  ./newvm.sh <vmname> <devuser>"
echo "  Restart the base to update it later:  incus start $BASE"
