#!/usr/bin/env bash
# build-base.sh (OrbStack) — build or refresh the devsys golden base machine.
#
# Run on the Mac that hosts OrbStack:
#   ./build-base.sh [base-machine]          # default: devsys-base
#
# It creates the base machine if it is missing, installs the pinned toolchain
# into it with devsys-vm.sh (no dev user, no Tailscale login), strips the
# per-machine identity, and leaves it STOPPED.  newvm.sh then clones it per
# developer.  OrbStack has no image store, so the stopped base machine IS the
# golden image — do not start it by hand; re-run this script to update it.
#
# Environment (all optional):
#   DEVSYS_GROUPS         install groups for the base (default: all)
#   DEVSYS_SHARED_CLAUDE  1 = bake the shared-Claude setup into the base
#   DEVSYS_BASE_IMAGE     distro image (default: ubuntu:resolute = 26.04 LTS)
#   DEVSYS_SCRIPT_FILE    local installer to use (default: devsys-vm.sh next to
#                         this script, when present)
#   DEVSYS_SCRIPT_URL     installer URL, used when there is no local installer
#                         (default: the devsys-v3.sh gist)
#   DEVSYS_ORB_USER       name of OrbStack's built-in default user
set -euo pipefail
BASE=${1:-devsys-base}
IMAGE=${DEVSYS_BASE_IMAGE:-ubuntu:resolute}
SCRIPT_URL=${DEVSYS_SCRIPT_URL:-https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/devsys-v3.sh}
# Installer source: an explicit file, else an explicit URL, else the devsys-vm.sh
# shipped next to this script, else the gist.
SCRIPT_FILE=${DEVSYS_SCRIPT_FILE:-}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -z $SCRIPT_FILE && -z ${DEVSYS_SCRIPT_URL:-} && -f $here/devsys-vm.sh ]]; then
  SCRIPT_FILE=$here/devsys-vm.sh
fi
[[ -z $SCRIPT_FILE || -f $SCRIPT_FILE ]] || { echo "No such installer: $SCRIPT_FILE" >&2; exit 1; }
# OrbStack always bakes one default user into a machine, named after the macOS
# account unless told otherwise.  A neutral name keeps the Mac admin's username
# out of every clone and cannot clash with a developer's own username.
ORB_USER=${DEVSYS_ORB_USER:-orbadmin}

command -v orbctl >/dev/null || { echo "orbctl not found — install OrbStack first." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found." >&2; exit 1; }
[[ $BASE =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid machine name: $BASE" >&2; exit 1; }

in_base() { orbctl run -m "$BASE" -u root "$@"; }
# Prints the machine's state, or nothing when it does not exist.
machine_state() { { orbctl info "$1" --format json 2>/dev/null || true; } | jq -r '.record.state // empty'; }

state=$(machine_state "$BASE")
if [[ -z $state ]]; then
  echo "▸ Creating base machine '$BASE' from ${IMAGE}…"
  # Isolated: without these flags OrbStack mounts the Mac's home (/mnt/mac) and
  # the other machines into the guest.  Clones inherit both settings.
  orbctl create --isolated --isolate-network --user "$ORB_USER" "$IMAGE" "$BASE"
elif [[ $state != running ]]; then
  echo "▸ Starting existing base machine '$BASE'…"
  orbctl start "$BASE"
else
  echo "▸ Reusing running base machine '$BASE'."
fi

in_base bash -c 'timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true'

# Put the installer in the machine as a file and run it from there (not
# `curl | bash`), so nothing it starts can read the script off stdin.
if [[ -n $SCRIPT_FILE ]]; then
  echo "▸ Using local installer ${SCRIPT_FILE}"
  in_base bash -c 'umask 077; cat > /root/devsys-install.sh' < "$SCRIPT_FILE"
else
  echo "▸ Fetching installer ${SCRIPT_URL}"
  # shellcheck disable=SC2016  # expanded inside the machine, not here
  in_base env URL="$SCRIPT_URL" bash -c \
    'umask 077; curl -fsSL --proto "=https" --tlsv1.2 --retry 3 "$URL" -o /root/devsys-install.sh'
fi
in_base bash -n /root/devsys-install.sh || { echo "Installer failed the syntax check." >&2; exit 1; }

echo "▸ Installing the toolchain into $BASE (first run takes several minutes)…"
install_env=(DEVSYS_UNATTENDED=1)
[[ -n ${DEVSYS_SCRIPT_URL:-} ]] && install_env+=(DEVSYS_SCRIPT_URL="$DEVSYS_SCRIPT_URL")
[[ -n ${DEVSYS_GROUPS:-} ]] && install_env+=(DEVSYS_GROUPS="$DEVSYS_GROUPS")
[[ -n ${DEVSYS_SHARED_CLAUDE:-} ]] && install_env+=(DEVSYS_SHARED_CLAUDE="$DEVSYS_SHARED_CLAUDE")
in_base env "${install_env[@]}" bash /root/devsys-install.sh install </dev/null

# The installer ends by fetching the published copy into /usr/local/bin/devsys.
# When a local installer was used, the base should carry that same version.
if [[ -n $SCRIPT_FILE ]]; then
  in_base install -m 0755 /root/devsys-install.sh /usr/local/bin/devsys
fi
in_base rm -f /root/devsys-install.sh

# "Generalize" is mandatory: otherwise every clone shares the base's machine-id
# and Tailscale identity, and they collide on the tailnet.
echo "▸ Generalizing $BASE (clearing per-machine identity)…"
in_base bash -euc '
  [ -x /usr/local/bin/devsys ] || { echo "devsys was not installed in the base." >&2; exit 1; }
  systemctl stop tailscaled 2>/dev/null || true
  rm -f /var/lib/tailscale/tailscaled.state
  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_*
  rm -f /root/.bash_history
  apt-get clean 2>/dev/null || true
'

echo "▸ Stopping ${BASE}…"
orbctl stop "$BASE"

echo "✔ Golden base '$BASE' is ready (stopped)."
echo "  Clone a dev VM with:  ./newvm.sh <vmname> <devuser>"
echo "  Update it later:      edit the pins, republish the gist, re-run ./build-base.sh"
