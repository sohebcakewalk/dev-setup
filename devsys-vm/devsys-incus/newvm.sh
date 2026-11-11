#!/usr/bin/env bash
# newvm.sh (v3, Incus) — clone a dev VM from the devsys golden image, mint a
# tagged Tailscale key, and let it join the tailnet unattended on first boot.
#
# Run on the Incus HOST (beehive):
#   ./newvm.sh <vmname> <devuser> [--login-link] [--project P] [--image ALIAS]
#
# Credentials: the Tailscale OAuth client is read from the environment
# (DEVSYS_TS_CLIENT_ID / DEVSYS_TS_CLIENT_SECRET) or, failing that, from a
# mode-600 file ~/.config/devsys/ts-oauth.env defining the same two vars.
#
# --login-link: create with NO auth key; afterwards the dev joins the VM to the
# tailnet under their own account via a printed browser link.
set -euo pipefail
usage="usage: newvm.sh <vmname> <devuser> [--login-link] [--project P] [--image ALIAS]"
VM=${1:?$usage}
DEVUSER=${2:?$usage}
shift 2
[[ $VM =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "Invalid VM name: $VM (lowercase letters, digits, hyphens)" >&2; exit 1; }
[[ $DEVUSER =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Invalid Linux username: $DEVUSER" >&2; exit 1; }

MODE="" PROJECT="" IMAGE_ALIAS="${DEVSYS_IMAGE:-devsys-base}"
while (($#)); do
  case $1 in
    --login-link) MODE="--login-link";;
    --project) PROJECT=${2:?$usage}; shift;;
    --image)   IMAGE_ALIAS=${2:?$usage}; shift;;
    *) echo "$usage" >&2; exit 1;;
  esac
  shift
done
PROJ_ARGS=(); [[ -n $PROJECT ]] && PROJ_ARGS=(--project "$PROJECT")

TEMPLATE_URL="${DEVSYS_TEMPLATE_URL:-https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/template-v3.yaml}"

# ── Mint a tagged, single-use auth key (unless --login-link) ─────────────────
KEY=""
if [[ $MODE != --login-link ]]; then
  : "${DEVSYS_TS_CLIENT_ID:=}"; : "${DEVSYS_TS_CLIENT_SECRET:=}"
  if [[ -z $DEVSYS_TS_CLIENT_ID || -z $DEVSYS_TS_CLIENT_SECRET ]]; then
    OAUTH_FILE=${DEVSYS_TS_OAUTH_FILE:-$HOME/.config/devsys/ts-oauth.env}
    # shellcheck disable=SC1090
    [[ -f $OAUTH_FILE ]] && . "$OAUTH_FILE"
  fi
  CID=${DEVSYS_TS_CLIENT_ID:?"Set DEVSYS_TS_CLIENT_ID or ~/.config/devsys/ts-oauth.env"}
  CSEC=${DEVSYS_TS_CLIENT_SECRET:?"Set DEVSYS_TS_CLIENT_SECRET or ~/.config/devsys/ts-oauth.env"}

  # Secrets go to curl on stdin (printf is a shell builtin), never as arguments,
  # so they do not show up in the host's process list.
  TOKEN=$(printf 'client_id=%s&client_secret=%s' "$CID" "$CSEC" | \
    curl -s -d @- https://api.tailscale.com/api/v2/oauth/token | jq -r .access_token)
  [[ $TOKEN != null && -n $TOKEN ]] || { echo "OAuth token exchange failed" >&2; exit 1; }

  RESP=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | \
    curl -s -X POST https://api.tailscale.com/api/v2/tailnet/-/keys \
    -H @- -H "Content-Type: application/json" \
    -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"tag:devsys\",\"tag:${DEVUSER}\"]}}},\"expirySeconds\":3600}")
  KEY=$(jq -r .key <<<"$RESP")
  [[ $KEY == tskey-auth-* ]] || {
    echo "Auth key mint failed: $(jq -r '.message // .' <<<"$RESP")" >&2
    echo "Hint: tagOwners must have 'tag:${DEVUSER}' owned by tag:devsys, and" >&2
    echo "tag:devsys must own ITSELF: \"tag:devsys\": [\"autogroup:admin\", \"tag:devsys\"]" >&2
    exit 1
  }
fi

# ── Render the light per-clone cloud-init ────────────────────────────────────
# Rendered in the shell, not with sed, so the auth key is never a command
# argument and never written to a file on the host.
USERDATA=$(curl -fsSL --proto '=https' --tlsv1.2 "$TEMPLATE_URL")
USERDATA=${USERDATA//VMNAME/"$VM"}
USERDATA=${USERDATA//USERNAME/"$DEVUSER"}
USERDATA=${USERDATA//@@TSKEY@@/"$KEY"}
[[ $USERDATA == *"hostname: $VM"* ]] || { echo "Template render failed" >&2; exit 1; }

# ── Launch the clone from the golden image ───────────────────────────────────
incus image info "$IMAGE_ALIAS" >/dev/null 2>&1 || {
  echo "No golden image '$IMAGE_ALIAS'. Build it first: ./build-base.sh" >&2; exit 1; }
echo "Cloning '$VM' from image '$IMAGE_ALIAS' for user '$DEVUSER'…"
# The instance config (with the user-data) is passed on stdin.  jq serializes
# it as JSON, which is valid YAML, so nothing in the template can add other
# config keys; jq reads the user-data on stdin too.
printf '%s\n' "$USERDATA" | jq -Rs '{config: {"cloud-init.user-data": .}}' | \
  incus launch "$IMAGE_ALIAS" "$VM" --vm "${PROJ_ARGS[@]}"

in_vm() { incus exec "$VM" "${PROJ_ARGS[@]}" -- "$@"; }
if [[ $MODE == --login-link ]]; then
  printf "VM '%s' created without an auth key.\nWaiting for the agent + Tailscale (1-3 min)" "$VM"
  ready="" tries=0
  while (( ++tries <= 60 )); do
    if in_vm command -v tailscale >/dev/null 2>&1; then ready=1; break; fi
    printf '.'; sleep 5
  done
  echo
  if [[ -z $ready ]]; then echo "Timed out. Fetch it later: incus exec $VM -- devsys ts-login"; exit 0; fi
  in_vm nohup sh -c "tailscale up --hostname='$VM' --ssh --accept-dns=false --accept-routes=true >/dev/null 2>&1 &" || true
  url="" tries=0
  while (( ++tries <= 30 )); do
    url=$(in_vm tailscale status --json 2>/dev/null | sed -n 's/.*"AuthURL": *"\([^"]*\)".*/\1/p' | head -1)
    [[ -n $url ]] && break; sleep 2
  done
  if [[ -n $url ]]; then
    printf '\nSend this link to the developer (must already be a tailnet member):\n  %s\n' "$url"
  else
    echo "Could not obtain the URL yet. Fetch it: incus exec $VM -- devsys ts-login"
  fi
else
  # The user-data holds the auth key and stays in the instance config.  Remove
  # it once cloud-init has used it on first boot.
  printf "VM '%s' created. Waiting for first boot to finish" "$VM"
  ready="" tries=0
  while (( ++tries <= 60 )); do
    if in_vm true >/dev/null 2>&1; then ready=1; break; fi
    printf '.'; sleep 5
  done
  echo
  if [[ -n $ready ]]; then
    in_vm timeout 600 cloud-init status --wait >/dev/null 2>&1 || true
    incus config unset "$VM" "${PROJ_ARGS[@]}" cloud-init.user-data
    echo "First boot done; the auth key is removed from the instance config."
  else
    echo "Timed out waiting for the VM agent. The auth key (single-use, 1 hour) is still in the" >&2
    echo "instance config. Remove it later: incus config unset $VM ${PROJ_ARGS[*]} cloud-init.user-data" >&2
  fi
  echo "It joins the tailnet as it boots — watch admin/machines."
fi
