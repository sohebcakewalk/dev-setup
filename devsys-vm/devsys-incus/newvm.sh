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

  TOKEN=$(curl -s -d "client_id=$CID" -d "client_secret=$CSEC" \
    https://api.tailscale.com/api/v2/oauth/token | jq -r .access_token)
  [[ $TOKEN != null && -n $TOKEN ]] || { echo "OAuth token exchange failed" >&2; exit 1; }

  RESP=$(curl -s -X POST https://api.tailscale.com/api/v2/tailnet/-/keys \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
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
umask 077
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 "$TEMPLATE_URL" | \
  sed -e "s/VMNAME/$VM/g" -e "s/USERNAME/$DEVUSER/g" -e "s|@@TSKEY@@|$KEY|g" > "$tmp"
grep -q "hostname: $VM" "$tmp" || { echo "Template render failed" >&2; exit 1; }

# ── Launch the clone from the golden image ───────────────────────────────────
incus image info "$IMAGE_ALIAS" >/dev/null 2>&1 || {
  echo "No golden image '$IMAGE_ALIAS'. Build it first: ./build-base.sh" >&2; exit 1; }
echo "Cloning '$VM' from image '$IMAGE_ALIAS' for user '$DEVUSER'…"
incus launch "$IMAGE_ALIAS" "$VM" --vm "${PROJ_ARGS[@]}" -c cloud-init.user-data="$(cat "$tmp")"

if [[ $MODE == --login-link ]]; then
  in_vm() { incus exec "$VM" "${PROJ_ARGS[@]}" -- "$@"; }
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
  echo "VM '$VM' created. It joins the tailnet as it boots — watch admin/machines."
fi
