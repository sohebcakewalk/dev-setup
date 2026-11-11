#!/usr/bin/env bash
# newvm.sh — mint a one-shot Tailscale auth key and create an OrbStack VM
# that bootstraps itself with devsys, fully unattended.
#
# Fully remote invocation (no local files needed beyond Keychain credentials):
#   curl -fsSL https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/newvm.sh | \
#     bash -s -- <vmname> <devuser> [--login-link] [--distro ubuntu|debian] [--release <codename>]
#
# Without --distro/--release, an interactive terminal is asked (defaults:
# ubuntu noble = 24.04 LTS, the supported devsys target); non-interactive
# runs take the defaults silently.
#
# --login-link: create the VM with NO auth key; afterwards fetch a Tailscale
# login URL with 'devsys ts-login' and send it to the developer, who joins
# the VM to the tailnet under their own account (must already be a member).
#
# Requires: OrbStack; for the default key mode also jq and the Tailscale
# OAuth client in the macOS Keychain:
#   security add-generic-password -s ts-oauth -a tailscaleclientid -w '<id>'
#   security add-generic-password -s ts-oauth -a tailscaleclientsecret -w '<secret>'
set -euo pipefail
usage="usage: newvm.sh <vmname> <devuser> [--login-link] [--distro ubuntu|debian] [--release <codename>] [--shared]"
VM=${1:?$usage}
DEVUSER=${2:?$usage}
shift 2

MODE="" DISTRO="" RELEASE="" SHARED=""
while (($#)); do
  case $1 in
    --login-link) MODE="--login-link";;
    --distro)  DISTRO=${2:?$usage}; shift;;
    --release) RELEASE=${2:?$usage}; shift;;
    --shared)  SHARED=1;;
    *) echo "$usage" >&2; exit 1;;
  esac
  shift
done

# Isolation is the default: without it OrbStack shares /mnt/mac (the host's
# home) and /mnt/machines/<other-vm> into every VM, so one developer could
# read another's files from inside their own VM — defeating the per-dev
# isolation enforced at the Tailscale layer.  --shared opts back in.
ISO_FLAGS=(--isolated --isolate-network)
[[ -n $SHARED ]] && ISO_FLAGS=()

# Numbered menu on a terminal when not given as flags; falls back to the
# default silently in non-interactive (scripted) runs.  Everything is written
# to /dev/tty directly so it survives any stdout/stderr redirection.  A menu
# entry's value is its first word; typing a literal value also works.
choose_tty() {
  local prompt=$1 default=$2; shift 2
  local options=("$@") answer="" i
  if { : </dev/tty; } 2>/dev/null; then
    {
      printf '%s\n' "$prompt"
      for i in "${!options[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"; done
      printf 'Choose 1-%d or type a value [%s]: ' "${#options[@]}" "$default"
    } >/dev/tty 2>/dev/null || true
    read -r answer </dev/tty 2>/dev/null || answer=""
  fi
  if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
    printf '%s' "${options[$((answer - 1))]%% *}"
  elif [[ -n $answer ]]; then
    printf '%s' "$answer"
  else
    printf '%s' "$default"
  fi
}
[[ -n $DISTRO ]] || DISTRO=$(choose_tty "Distribution (devsys is apt-based, so only these):" "ubuntu" \
  "ubuntu   (recommended — 24.04 LTS is the supported devsys target)" \
  "debian")
case $DISTRO in
  ubuntu) def_release="noble"
          releases=("noble    (24.04 LTS — supported devsys target)"
                    "jammy    (22.04 LTS)"
                    "resolute (26.04 LTS)");;
  debian) def_release="bookworm"
          releases=("bookworm (Debian 12)"
                    "trixie   (Debian 13)");;
  *) echo "devsys supports ubuntu/debian only (got '$DISTRO')" >&2; exit 1;;
esac
[[ -n $RELEASE ]] || RELEASE=$(choose_tty "$DISTRO release:" "$def_release" "${releases[@]}")
[[ $RELEASE =~ ^[a-z0-9.]+$ ]] || { echo "Invalid release: $RELEASE" >&2; exit 1; }
IMAGE="$DISTRO:$RELEASE"

# The template is fetched from the same gist; override while testing a fork.
TEMPLATE_URL="${DEVSYS_TEMPLATE_URL:-https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/template.yaml}"

KEY=""
if [[ $MODE != --login-link ]]; then
  CID=$(security find-generic-password -s ts-oauth -a tailscaleclientid -w)
  CSEC=$(security find-generic-password -s ts-oauth -a tailscaleclientsecret -w)

  TOKEN=$(curl -s -d "client_id=$CID" -d "client_secret=$CSEC" \
    https://api.tailscale.com/api/v2/oauth/token | jq -r .access_token)
  [[ $TOKEN != null && -n $TOKEN ]] || { echo "OAuth token exchange failed" >&2; exit 1; }

  RESP=$(curl -s -X POST https://api.tailscale.com/api/v2/tailnet/-/keys \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"tag:devsys\",\"tag:${DEVUSER}\"]}}},\"expirySeconds\":3600}")
  KEY=$(jq -r .key <<<"$RESP")
  [[ $KEY == tskey-auth-* ]] || {
    echo "Auth key mint failed: $(jq -r '.message // .' <<<"$RESP")" >&2
    echo "Hint: in tailnet ACL tagOwners, 'tag:${DEVUSER}' must be owned by tag:devsys," >&2
    echo "and tag:devsys must own ITSELF (\"tag:devsys\": [\"autogroup:admin\", \"tag:devsys\"])" >&2
    echo "— multi-tag keys require every tag, including tag:devsys, to pass ownership." >&2
    exit 1
  }
fi

# The rendered file briefly holds a live (single-use, 1h) auth key: keep it
# owner-only and remove it on every exit path.
umask 077
trap 'rm -f "/tmp/$VM.yaml"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 "$TEMPLATE_URL" | \
  sed -e "s/VMNAME/$VM/g" -e "s/USERNAME/$DEVUSER/g" -e "s|@@TSKEY@@|$KEY|g" \
  > "/tmp/$VM.yaml"
grep -q "hostname: $VM" "/tmp/$VM.yaml" || { echo "Template render failed" >&2; exit 1; }
echo "Creating '$VM' from $IMAGE for user '$DEVUSER'${SHARED:+ (shared FS)}…"
orbctl create "${ISO_FLAGS[@]}" -c "/tmp/$VM.yaml" "$IMAGE" "$VM"
if [[ $MODE == --login-link ]]; then
  # Fetch the developer login link right here: wait for cloud-init to install
  # Tailscale (early in the devsys system stage), start the login flow
  # detached on the VM, and lift the URL from the daemon.  Falls back to the
  # manual command if the VM takes too long.
  orb_ssh() { ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$VM@orb" "$@"; }
  manual_hint() { cat <<EOF
Fetch the developer login link manually once the install finishes:
  ssh root@$VM@orb devsys ts-login
EOF
  }
  printf "VM '%s' created without an auth key.\nWaiting for it to install Tailscale (usually 1-3 minutes)" "$VM"
  ready="" tries=0
  while (( ++tries <= 60 )); do
    if orb_ssh 'command -v tailscale' >/dev/null 2>&1; then ready=1; break; fi
    printf '.'; sleep 5
  done
  echo
  if [[ -z $ready ]]; then echo "Timed out waiting for Tailscale."; manual_hint; exit 0; fi
  orb_ssh "nohup tailscale up --hostname='$VM' --ssh --accept-dns=false --accept-routes=true >/dev/null 2>&1 & sleep 1" || true
  url="" tries=0
  while (( ++tries <= 30 )); do
    url=$(orb_ssh 'tailscale status --json' 2>/dev/null | sed -n 's/.*"AuthURL": *"\([^"]*\)".*/\1/p' | head -1)
    [[ -n $url ]] && break
    sleep 2
  done
  if [[ -n $url ]]; then
    cat <<EOF

Send this link to the developer; signing in joins '$VM' under their account
(the link stays valid until used):
  $url

IMPORTANT: they must already be a member of your tailnet, or the VM will
join their personal tailnet instead.  The rest of the install continues on
the VM by itself.
EOF
  else
    echo "Could not obtain the login URL yet."; manual_hint
  fi
else
  echo "VM '$VM' created. Watch it appear at https://login.tailscale.com/admin/machines"
fi
