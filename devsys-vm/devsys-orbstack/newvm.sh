#!/usr/bin/env bash
# newvm.sh (OrbStack) — clone a dev VM from the devsys golden base machine,
# mint a tagged Tailscale key, and join the clone to the tailnet.
#
# Run on the Mac that hosts OrbStack:
#   ./newvm.sh <vmname> <devuser> [--tag NAME] [--ollama ADDR] [--login-link] [--base NAME]
#
# --ollama ADDR: point every user of the VM at an Ollama server, normally the
# one on this Mac, by setting OLLAMA_HOST system-wide in the clone.  ADDR is an
# IP or host name, optionally with http(s):// and a port (default port 11434);
# DEVSYS_OLLAMA_HOST in the environment is the default.  Use the Mac's LAN
# address: an isolated machine cannot reach the Mac by its OrbStack host name.
#
# The VM joins Tailscale tagged tag:devsys + tag:<NAME>.  NAME defaults to
# <devuser>; pass --tag to name the tag after the VM or the person instead, so
# the Linux username can be anything (two VMs may both have a user "admin").
#
# Credentials: the Tailscale OAuth client is read, in this order, from
#   1. the environment: DEVSYS_TS_CLIENT_ID / DEVSYS_TS_CLIENT_SECRET
#   2. a mode-600 file ~/.config/devsys/ts-oauth.env defining the same two vars
#   3. the macOS Keychain (the items the earlier OrbStack scripts used):
#        security add-generic-password -s ts-oauth -a tailscaleclientid -w '<id>'
#        security add-generic-password -s ts-oauth -a tailscaleclientsecret -w '<secret>'
#
# --login-link: create with NO auth key; the script prints a browser link and
# the dev joins the VM to the tailnet under their own account.
set -euo pipefail
usage="usage: newvm.sh <vmname> <devuser> [--tag NAME] [--ollama ADDR] [--login-link] [--base NAME]"
VM=${1:?$usage}
DEVUSER=${2:?$usage}
shift 2

MODE="" BASE="${DEVSYS_BASE:-devsys-base}" TAG="" OLLAMA="${DEVSYS_OLLAMA_HOST:-}"
while (($#)); do
  case $1 in
    --login-link) MODE="--login-link";;
    --base) BASE=${2:?$usage}; shift;;
    --tag) TAG=${2:?$usage}; shift;;
    --ollama) OLLAMA=${2:?$usage}; shift;;
    *) echo "$usage" >&2; exit 1;;
  esac
  shift
done

command -v orbctl >/dev/null || { echo "orbctl not found — install OrbStack first." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found." >&2; exit 1; }
# Both names end up in a JSON body and a hostname, so keep them strict.
[[ $VM =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid VM name: $VM (lowercase letters, digits, hyphens)" >&2; exit 1; }
[[ $DEVUSER =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Invalid Linux username: $DEVUSER" >&2; exit 1; }
# The tag also ends up in the JSON body.  "tag:" is added below, so drop it if given.
TAG=${TAG#tag:}
TAG=${TAG:-$DEVUSER}
[[ $TAG =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid tag name: $TAG (lowercase letters, digits, hyphens)" >&2; exit 1; }
# The Ollama address is written into a shell profile in the clone, so it must be
# nothing but a plain URL: scheme, host, port.
if [[ -n $OLLAMA ]]; then
  [[ $OLLAMA == http://* || $OLLAMA == https://* ]] || OLLAMA="http://$OLLAMA"
  [[ $OLLAMA =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || {
    echo "Invalid Ollama address: $OLLAMA (use an IP or host name, optionally with http:// and :port)" >&2; exit 1; }
  [[ $OLLAMA =~ :[0-9]+$ ]] || OLLAMA="$OLLAMA:11434"
fi

# Prints the machine's state, or nothing when it does not exist.
machine_state() { { orbctl info "$1" --format json 2>/dev/null || true; } | jq -r '.record.state // empty'; }

# ── Check the golden base before spending a Tailscale key ────────────────────
base_state=$(machine_state "$BASE")
[[ -n $base_state ]] || { echo "No base machine '$BASE'. Build it first: ./build-base.sh" >&2; exit 1; }
# A running base has a live machine-id and Tailscale identity that every clone
# would copy.  build-base.sh clears both and stops it.
[[ $base_state == stopped ]] || {
  echo "Base '$BASE' is $base_state, not stopped. Re-run ./build-base.sh to generalize and stop it." >&2; exit 1; }
[[ -z $(machine_state "$VM") ]] || { echo "A machine named '$VM' already exists." >&2; exit 1; }

# ── Mint a tagged, single-use auth key (unless --login-link) ─────────────────
KEY=""
if [[ $MODE != --login-link ]]; then
  : "${DEVSYS_TS_CLIENT_ID:=}"; : "${DEVSYS_TS_CLIENT_SECRET:=}"
  if [[ -z $DEVSYS_TS_CLIENT_ID || -z $DEVSYS_TS_CLIENT_SECRET ]]; then
    OAUTH_FILE=${DEVSYS_TS_OAUTH_FILE:-$HOME/.config/devsys/ts-oauth.env}
    # shellcheck disable=SC1090
    [[ -f $OAUTH_FILE ]] && . "$OAUTH_FILE"
  fi
  if [[ -z $DEVSYS_TS_CLIENT_ID || -z $DEVSYS_TS_CLIENT_SECRET ]]; then
    DEVSYS_TS_CLIENT_ID=$(security find-generic-password -s ts-oauth -a tailscaleclientid -w 2>/dev/null || true)
    DEVSYS_TS_CLIENT_SECRET=$(security find-generic-password -s ts-oauth -a tailscaleclientsecret -w 2>/dev/null || true)
  fi
  CID=${DEVSYS_TS_CLIENT_ID:?"No Tailscale OAuth client: set DEVSYS_TS_CLIENT_ID, ~/.config/devsys/ts-oauth.env, or the ts-oauth Keychain items"}
  CSEC=${DEVSYS_TS_CLIENT_SECRET:?"No Tailscale OAuth secret: set DEVSYS_TS_CLIENT_SECRET, ~/.config/devsys/ts-oauth.env, or the ts-oauth Keychain items"}

  # Secrets go to curl on stdin (printf is a shell builtin), never as arguments,
  # so they do not show up in the host's process list.
  TOKEN=$(printf 'client_id=%s&client_secret=%s' "$CID" "$CSEC" | \
    curl -s -d @- https://api.tailscale.com/api/v2/oauth/token | jq -r .access_token)
  [[ $TOKEN != null && -n $TOKEN ]] || { echo "OAuth token exchange failed" >&2; exit 1; }

  RESP=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | \
    curl -s -X POST https://api.tailscale.com/api/v2/tailnet/-/keys \
    -H @- -H "Content-Type: application/json" \
    -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"tag:devsys\",\"tag:${TAG}\"]}}},\"expirySeconds\":3600}")
  KEY=$(jq -r .key <<<"$RESP")
  [[ $KEY == tskey-auth-* ]] || {
    echo "Auth key mint failed: $(jq -r '.message // .' <<<"$RESP")" >&2
    echo "Hint: tagOwners must have 'tag:${TAG}' owned by tag:devsys, and" >&2
    echo "tag:devsys must own ITSELF: \"tag:devsys\": [\"autogroup:admin\", \"tag:devsys\"]" >&2
    exit 1
  }
fi

# ── Clone the golden base ────────────────────────────────────────────────────
# The clone keeps the base's isolation settings; OrbStack gives it its own
# hostname, and the empty machine-id is regenerated on its first boot.
echo "Cloning '$VM' from '$BASE' for user '$DEVUSER'…"
orbctl clone "$BASE" "$VM"
orbctl start "$VM"

# ── Per-clone setup: dev user + Tailscale join ───────────────────────────────
# `orbctl clone` takes no cloud-init, so this replaces the Incus template.yaml.  The
# auth key travels on stdin (never in a process argument list or a file), and
# the script below is a constant — nothing from this host is spliced into it.
# shellcheck disable=SC2016  # expanded inside the machine, not here
if ! printf '%s\n' "$KEY" | orbctl run -m "$VM" -u root \
  env DEVSYS_UNATTENDED=1 DEVSYS_USER="$DEVUSER" DEVSYS_TS_HOSTNAME="$VM" DEVSYS_OLLAMA_HOST="$OLLAMA" bash -c '
    set -euo pipefail
    IFS= read -r key || true
    [ -x /usr/local/bin/devsys ] || { echo "The base has no devsys; re-run build-base.sh." >&2; exit 1; }
    # Ollama address for every user of this VM, in both shells.
    if [ -n "$DEVSYS_OLLAMA_HOST" ]; then
      printf "export OLLAMA_HOST=%s\n" "$DEVSYS_OLLAMA_HOST" > /etc/profile.d/devsys-ollama.sh
      chmod 0644 /etc/profile.d/devsys-ollama.sh
      src="[ -f /etc/profile.d/devsys-ollama.sh ] && . /etc/profile.d/devsys-ollama.sh"
      mkdir -p /etc/zsh
      for rc in /etc/zsh/zshenv /etc/bash.bashrc; do
        grep -qxF "$src" "$rc" 2>/dev/null || printf "%s\n" "$src" >> "$rc"
      done
    fi
    timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true
    # Start from a clean Tailscale identity even if the base kept one.
    systemctl stop tailscaled 2>/dev/null || true
    rm -f /var/lib/tailscale/tailscaled.state
    systemctl start tailscaled
    for _ in $(seq 30); do [ -S /run/tailscale/tailscaled.sock ] && break; sleep 1; done
    if [ -n "$key" ]; then
      DEVSYS_TS_AUTHKEY="$key" /usr/local/bin/devsys install none
      exit 0
    fi
    # --login-link: user only, then hand back a browser login URL.
    /usr/local/bin/devsys install none
    setsid nohup tailscale up --hostname="$DEVSYS_TS_HOSTNAME" --ssh \
      --accept-dns=false --accept-routes=true >/dev/null 2>&1 &
    url=""
    for _ in $(seq 30); do
      url=$(tailscale status --json 2>/dev/null | sed -n "s/.*\"AuthURL\": *\"\([^\"]*\)\".*/\1/p" | head -1)
      [ -n "$url" ] && break; sleep 2
    done
    if [ -n "$url" ]; then
      printf "\nSend this link to the developer (must already be a tailnet member):\n  %s\n" "$url"
    else
      echo "Could not obtain the login URL yet. Fetch it: orbctl run -m $DEVSYS_TS_HOSTNAME -u root devsys ts-login"
    fi
  '
then
  echo "Setup inside '$VM' failed. Inspect it:  orbctl run -m $VM -u root bash" >&2
  echo "or remove it and retry:             orbctl delete $VM" >&2
  exit 1
fi

if [[ $MODE == --login-link ]]; then
  echo "VM '$VM' created without an auth key."
else
  echo "VM '$VM' created and joined to the tailnet — check admin/machines."
fi
[[ -z $OLLAMA ]] || echo "OLLAMA_HOST=$OLLAMA is set for every user of '$VM'."
