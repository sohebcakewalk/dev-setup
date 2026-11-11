#!/usr/bin/env bash
# devsys-vm — Homebrew-first Ubuntu/Debian development VM bootstrap.
#
# Publish this file and use:
#   curl -fsSL https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/devsys-vm.sh | bash
#
# Root runs the system stage, creates/selects a development user, then downloads
# this same published script and runs its user stage as that user.  Set
# DEVSYS_SCRIPT_URL to a different raw URL while testing a fork.
#
# shellcheck disable=SC1090,SC1091,SC2015,SC2016
# (deliberate: runtime-sourced env files; `A && ok || warn` where ok/warn
# cannot fail; literal single-quoted lines written to shell startup files)
set -Eeuo pipefail

# cloud-init's runcmd runs with a minimal environment where HOME can be unset;
# under set -u the first ${HOME} expansion would abort the script.
: "${HOME:=/root}"

DEVSYS_VERSION="2.5.0"
GIST_RAW_URL="${DEVSYS_SCRIPT_URL:-https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/devsys-vm.sh}"
SELF_PATH="/usr/local/bin/devsys"
CFG_DIR="${HOME}/.config/devsys"
WORK_DIR="${DEVSYS_WORK_DIR:-${HOME}/work}"
BREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW_BIN="${BREW_PREFIX}/bin/brew"
# Dedicated system account that owns the shared toolchain.  Every dev user
# runs the same central install from PATH; nothing is installed per user.
BREW_OWNER="linuxbrew"
# Every tool is version-pinned so all VMs run an identical environment.
# Binary tools are pinned through mise (Homebrew cannot pin exact versions,
# so brew's only job is delivering mise itself); JS tools are pinned through
# npm below.  Change a pin deliberately, publish, then rerun the toolchain
# stage on each VM (devsys update && sudo devsys install).
MISE_TOOLS=(
  node@26.5.0 bun@1.3.14 python@3.12.13
  age@1.3.1 bat@0.26.1 direnv@2.37.1 eza@0.23.5 fd@10.4.2 flyctl@0.4.78
  fzf@0.74.2 gh@2.96.0 glow@2.1.2 jq@1.8.2 lazygit@0.64.0 micro@2.0.15
  ripgrep@15.2.0 starship@1.26.0
)
NPM_CLIS=(
  pnpm@11.21.0 neonctl@3.1.1 @tigrisdata/cli@3.7.0
  @anthropic-ai/claude-code@2.1.227 @openai/codex@0.147.0
  @google/gemini-cli@0.54.4 opencode-ai@1.18.16
)
MISE_DATA="/home/linuxbrew/.local/share/mise"
MISE_CONFIG="/home/linuxbrew/.config/mise/config.toml"
TIGRIS_ENV="${CFG_DIR}/tigris.env"
CURL_OPTS=(-fsSL --proto '=https' --tlsv1.2 --retry 3)

if [[ -t 2 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else C_R=; C_G=; C_Y=; C_B=; C_0=; fi
log()  { printf '%s\n' "${C_B}▸${C_0} $*" >&2; }
ok()   { printf '%s\n' "${C_G}✔${C_0} $*" >&2; }
warn() { printf '%s\n' "${C_Y}⚠${C_0} $*" >&2; }
err()  { printf '%s\n' "${C_R}✗${C_0} $*" >&2; }
trap 'err "devsys: command failed (line $LINENO): $BASH_COMMAND"' ERR

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ $(id -u) -eq 0 ]]; }
as_root() { if is_root; then "$@"; else sudo "$@"; fi; }
require_tty() { { : </dev/tty; } 2>/dev/null || { err "This command needs an interactive terminal."; return 1; }; }
ensure_not_root() { if is_root; then err "Homebrew and user-install cannot run as root."; return 1; fi; }

ask() {
  local prompt=$1 default=${2:-} answer
  if [[ -n $default ]]; then printf '%s [%s]: ' "$prompt" "$default" >&2; else printf '%s: ' "$prompt" >&2; fi
  read -r answer </dev/tty || answer=""
  printf '%s' "${answer:-$default}"
}
ask_secret() { local answer; printf '%s: ' "$1" >&2; read -rs answer </dev/tty || answer=""; printf '\n' >&2; printf '%s' "$answer"; }
confirm() { local answer; printf '%s [y/N]: ' "$1" >&2; read -r answer </dev/tty || answer=""; [[ $answer == [yY] ]]; }
backup_once() { [[ -e $1 && ! -e $1.devsys.bak ]] && cp -a "$1" "$1.devsys.bak" && warn "Backed up $1 -> $1.devsys.bak" || true; }
run_step() { local label=$1; shift; log "$label"; "$@" && ok "$label" || { err "Failed: $label"; return 1; }; }

require_apt() { have apt-get || { err "devsys supports Ubuntu/Debian only (apt-get is missing)."; return 1; }; }
apt_update() { as_root apt-get update -y; }

SYSTEM_PACKAGES=(
  ca-certificates curl file git gnupg lsb-release sudo unzip zip
  build-essential bubblewrap pkg-config procps openssh-client
  iputils-ping dnsutils net-tools rsync tmux zsh htop ncdu
  postgresql-client redis-server
)
install_system_packages() {
  require_apt; apt_update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${SYSTEM_PACKAGES[@]}"
}

os_release_value() { [[ -r /etc/os-release ]] && (. /etc/os-release && eval "printf '%s' \"\${$1:-}\"") || true; }
install_tailscale() {
  have tailscale && return 0
  local id codename
  id=$(os_release_value ID); codename=$(os_release_value VERSION_CODENAME)
  case "$id" in ubuntu|debian) ;; *) id=ubuntu;; esac
  [[ -n $codename ]] || codename=$(lsb_release -cs 2>/dev/null || printf 'noble')
  curl "${CURL_OPTS[@]}" "https://pkgs.tailscale.com/stable/${id}/${codename}.noarmor.gpg" | as_root tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl "${CURL_OPTS[@]}" "https://pkgs.tailscale.com/stable/${id}/${codename}.tailscale-keyring.list" | as_root tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt_update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
  as_root systemctl enable --now tailscaled 2>/dev/null || true
}

install_system_stage() {
  is_root || { err "system-install must be run as root (use sudo devsys system-install)."; return 1; }
  # Supported target platform: Ubuntu 24.04 LTS (noble).  Other recent
  # Ubuntu/Debian releases generally work, so this is a heads-up, not a block.
  local codename; codename=$(os_release_value VERSION_CODENAME)
  [[ $codename == noble ]] || warn "devsys targets Ubuntu 24.04 (noble); running on '${codename:-unknown}'."
  run_step "System packages" install_system_packages
  run_step "Tailscale service" install_tailscale
  systemctl enable --now redis-server 2>/dev/null || warn "Redis was installed but could not be enabled."
  [[ -f /etc/tmux.conf ]] || printf 'set -g mouse on\n' > /etc/tmux.conf
}

valid_username() { [[ ${1:-} =~ ^[a-z_][a-z0-9_-]*$ ]]; }
select_dev_user() {
  local user=${DEVSYS_USER:-}
  if [[ -z $user ]]; then user=$(ask "Development username" "${SUDO_USER:-dev}"); fi
  valid_username "$user" || { err "Invalid Linux username: $user"; return 1; }
  if ! id "$user" >/dev/null 2>&1; then
    if [[ ${DEVSYS_UNATTENDED:-} == 1 ]]; then
      # No password on purpose: Tailscale SSH (or admin-installed keys) is the
      # front door, and an unused password is just attack surface.
      log "Creating user '$user' (unattended, password disabled)."
      adduser --disabled-password --gecos "" "$user" >&2
    else
      log "Creating user '$user' (choose its password now)."
      # stdout is captured by the caller, so adduser's chatter must go to stderr.
      adduser "$user" >&2 </dev/tty
    fi
  fi
  usermod -aG sudo "$user"
  printf '%s' "$user"
}

# The toolchain (Homebrew, brew packages, npm CLIs) is installed once, owned
# by the dedicated '$BREW_OWNER' system account, and shared by every dev user
# through the world-readable prefix on PATH.  Adding a user never reinstalls.
ensure_brew_owner() {
  if ! id "$BREW_OWNER" >/dev/null 2>&1; then
    adduser --system --group --home "$(dirname "$BREW_PREFIX")" "$BREW_OWNER" >&2
  fi
  install -d -o "$BREW_OWNER" -g "$BREW_OWNER" "$(dirname "$BREW_PREFIX")" "$BREW_PREFIX"
  # Adopt a prefix installed by an older per-user devsys.
  [[ $(stat -c %U "$BREW_PREFIX") == "$BREW_OWNER" ]] || chown -R "$BREW_OWNER:$BREW_OWNER" "$(dirname "$BREW_PREFIX")"
}

handoff_toolchain() {
  log "Installing the shared toolchain as '$BREW_OWNER' (unattended)…"
  sudo -Hu "$BREW_OWNER" env DEVSYS_SCRIPT_URL="$GIST_RAW_URL" DEVSYS_HANDOFF=1 \
    bash -c 'cd "$HOME" && curl -fsSL --proto "=https" --tlsv1.2 --retry 3 "$DEVSYS_SCRIPT_URL" | bash -s -- toolchain-install'
}

toolchain_install() {
  ensure_not_root
  run_step "Homebrew" install_homebrew
  run_step "Homebrew packages" install_brew_packages
  run_step "Pinned tools (mise)" install_pinned_tools
  run_step "npm global CLIs" install_npm_clis
}

# Run brew/npm as the toolchain owner ('devsys brew install foo').  Root gets
# no password prompt; dev users authenticate through their own sudo.
run_as_brew_owner() {
  id "$BREW_OWNER" >/dev/null 2>&1 || { err "Shared toolchain is not set up; run the installer as root first."; return 1; }
  sudo -Hu "$BREW_OWNER" bash -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"; [[ -d $HOME/.local/share/mise/shims ]] && PATH="$HOME/.local/share/mise/shims:$PATH"; cd "$HOME"; exec "$@"' _ "$@"
}
cmd_brew() { run_as_brew_owner brew "$@"; }
cmd_npm() { run_as_brew_owner npm "$@"; }
cmd_mise() { run_as_brew_owner mise "$@"; }

# Root-side preparation that removes every sudo prompt from the user stage.
# Nested sudo password prompts deadlock under the piped handoff (sudo's
# default use_pty suspends the inner prompt), so root does this work up front.
prepare_user_system() {
  local user=$1
  chsh -s "$(command -v zsh)" "$user" || warn "Could not set zsh as the login shell for $user."
}

handoff_to_user() {
  local user=$1
  log "Continuing Homebrew and user setup as '$user' (unattended)…"
  # A curl|bash invocation has no durable source file, so fetch the canonical
  # script again.  DEVSYS_SCRIPT_URL lets a tested fork use this same handoff.
  # Plain `sudo -Hu` (not -i): a login shell re-parses the command string and
  # expands $DEVSYS_SCRIPT_URL to empty before env(1) has set it.
  sudo -Hu "$user" env DEVSYS_SCRIPT_URL="$GIST_RAW_URL" DEVSYS_WORK_DIR="${DEVSYS_WORK_DIR:-}" DEVSYS_HANDOFF=1 \
    bash -c 'cd "$HOME" && curl -fsSL --proto "=https" --tlsv1.2 --retry 3 "$DEVSYS_SCRIPT_URL" | bash -s -- user-install'
}

brew_env() {
  [[ -x $BREW_BIN ]] && eval "$("$BREW_BIN" shellenv)" || true
  # Shared pinned runtimes: every user resolves the owner's mise installs.
  if [[ -d $MISE_DATA/shims ]]; then
    export MISE_DATA_DIR="$MISE_DATA" MISE_GLOBAL_CONFIG_FILE="$MISE_CONFIG"
    export PATH="$MISE_DATA/shims:$PATH"
  fi
}
ensure_brew_prefix() {
  [[ -d $BREW_PREFIX && -w $BREW_PREFIX ]] && return 0
  if [[ ${DEVSYS_HANDOFF:-} == 1 ]]; then
    err "$BREW_PREFIX is missing or not writable; run the installer as root first."; return 1
  fi
  log "Creating $BREW_PREFIX (sudo may ask for your password)."
  as_root install -d -o "$USER" -g "$(id -gn)" "$BREW_PREFIX"
}
install_homebrew() {
  ensure_not_root
  if [[ ! -x $BREW_BIN ]]; then
    ensure_brew_prefix
    log "Installing Homebrew."
    # The prefix is already user-owned, so the installer needs no sudo and
    # NONINTERACTIVE skips its confirmation prompt (required for the handoff).
    NONINTERACTIVE=1 /bin/bash -c "$(curl "${CURL_OPTS[@]}" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew_env
  have brew || { err "Homebrew was not found after installation."; return 1; }
}

write_brewfile() {
  mkdir -p "$CFG_DIR"
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
# Everything version-pinned lives in MISE_TOOLS/NPM_CLIS in devsys-vm.sh;
# brew only delivers mise.  Add unpinned extras here if you accept drift.
brew "mise"
EOF
  if [[ -f $CFG_DIR/Brewfile ]] && ! cmp -s "$tmp" "$CFG_DIR/Brewfile"; then
    warn "Keeping your customized $CFG_DIR/Brewfile (delete it to restore the default list)."
  else
    cat "$tmp" > "$CFG_DIR/Brewfile"
  fi
  rm -f "$tmp"
}
install_brew_packages() { brew_env; write_brewfile; brew bundle --file "$CFG_DIR/Brewfile"; }
install_pinned_tools() {
  brew_env
  have mise || { err "mise is missing; the Homebrew stage must have failed."; return 1; }
  mise install "${MISE_TOOLS[@]}"
  mise use --global "${MISE_TOOLS[@]}"
  mise reshim
}
install_npm_clis() {
  brew_env
  have npm || { err "npm is missing; the pinned node install must have failed."; return 1; }
  local package
  for package in "${NPM_CLIS[@]}"; do
    npm install -g "$package"
  done
  npm install -g obsidian-headless@0.0.14 || warn "Optional CLI obsidian-headless was not installed."
  # Expose freshly installed global binaries through the shared shims.
  have mise && mise reshim || true
}

append_managed_block() {
  local file=$1; mkdir -p "$(dirname "$file")"; touch "$file"; backup_once "$file"
  local tmp; tmp=$(mktemp)
  awk '/^# >>> devsys >>>$/ {skip=1; next} /^# <<< devsys <<<$/{skip=0; next} !skip {print}' "$file" > "$tmp"
  cat >> "$tmp" <<'EOF'
# >>> devsys >>>
export MISE_DATA_DIR="/home/linuxbrew/.local/share/mise"
export MISE_GLOBAL_CONFIG_FILE="/home/linuxbrew/.config/mise/config.toml"
export PATH="$MISE_DATA_DIR/shims:/home/linuxbrew/.linuxbrew/bin:$HOME/.fly/bin:$PATH"
command -v direnv >/dev/null && eval "$(direnv hook zsh)"
command -v starship >/dev/null && eval "$(starship init zsh)"
alias ls='eza'
alias ll='eza -la --git'
alias tree='eza --tree'
alias cat='bat --paging=never'
alias lg='lazygit'
# <<< devsys <<<
EOF
  # Overwrite in place so the file keeps its original permissions and owner.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}
configure_shell() {
  mkdir -p "$WORK_DIR"
  append_managed_block "$HOME/.zshrc"
  grep -qxF 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' "$HOME/.zprofile" 2>/dev/null || \
    printf '%s\n' 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  if have zsh && [[ ${SHELL:-} != "$(command -v zsh)" ]]; then
    sudo chsh -s "$(command -v zsh)" "$USER" || warn "Could not set zsh as your login shell."
  fi
}

configure_ai() {
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.gemini"
  # Authentication remains per-user.  Do not weaken approval/sandbox defaults:
  # users can opt into tool-specific automation in their own configuration.
  [[ -f $HOME/.codex/config.toml ]] || printf '%s\n' '# Devsys leaves Codex approval and sandbox settings at their secure defaults.' > "$HOME/.codex/config.toml"
}

# Tailscale connect. Environment variables answer every question so the whole
# step can run unattended (cloud-init has no terminal); when they are absent
# and a TTY exists, the original interactive prompts are used instead.
#   DEVSYS_TS_AUTHKEY   auth key (tskey-auth-…). Presence selects the
#                       non-interactive path. Mint non-ephemeral, preauthorized,
#                       tagged keys (the provisioning script does this).
#   DEVSYS_TS_HOSTNAME  node hostname   (default: hostname -s)
#   DEVSYS_TS_TAGS      e.g. tag:devsys (optional when the key itself is tagged)
setup_tailscale() {
  have tailscale || { err "Tailscale is not installed."; return 1; }
  if tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then ok "Tailscale is already connected."; return 0; fi
  local hostname=${DEVSYS_TS_HOSTNAME:-} key=${DEVSYS_TS_AUTHKEY:-} tags=${DEVSYS_TS_TAGS:-} extra=()
  [[ -n $tags ]] && extra+=(--advertise-tags="$tags")
  if [[ -n $key ]]; then
    [[ -n $hostname ]] || hostname=$(hostname -s)
    as_root tailscale up --authkey="$key" --hostname="$hostname" --ssh \
      --accept-dns=false --accept-routes=true "${extra[@]}"
    return
  fi
  require_tty || { warn "No terminal and no DEVSYS_TS_AUTHKEY; skipping Tailscale connect."; return 0; }
  hostname=$(ask "Tailscale hostname" "${hostname:-$(hostname -s)}")
  if confirm "Use an auth key (No opens the browser-login URL)?"; then
    key=$(ask_secret "Tailscale auth key"); [[ -n $key ]] || return 1
    as_root tailscale up --authkey="$key" --hostname="$hostname" --ssh --accept-dns=false --accept-routes=true "${extra[@]}"
  else
    as_root tailscale up --hostname="$hostname" --ssh --accept-dns=false --accept-routes=true "${extra[@]}"
  fi
}

# Developer-login onboarding: prints a browser link that joins this VM to the
# tailnet under whichever Tailscale account completes it — no admin auth key.
# The developer must ALREADY be a member of the tailnet; otherwise the VM
# joins their personal tailnet instead of yours.
cmd_ts_login() {
  have tailscale || { err "Tailscale is not installed."; return 1; }
  if as_root tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
    ok "Tailscale is already connected."; return 0
  fi
  local hostname=${DEVSYS_TS_HOSTNAME:-$(hostname -s)} url="" tries=0
  # 'tailscale up' blocks until the login completes, so start it detached and
  # lift the login URL from the daemon instead.  The link stays valid until
  # it is used; nobody needs to keep this command running.
  as_root tailscale up --hostname="$hostname" --ssh --accept-dns=false --accept-routes=true >/dev/null 2>&1 &
  disown
  while (( ++tries <= 30 )); do
    url=$(as_root tailscale status --json 2>/dev/null | sed -n 's/.*"AuthURL": *"\([^"]*\)".*/\1/p' | head -1)
    [[ -n $url ]] && break
    sleep 1
  done
  [[ -n $url ]] || { err "Could not obtain a login URL from tailscaled."; return 1; }
  log "Send this link to the developer (they must already be a tailnet member); signing in joins this VM under their account:"
  printf '%s\n' "$url"
}

login_specs() { cat <<'EOF'
claude|test -e "$HOME/.claude/.credentials.json"|claude
gh|gh auth status|gh auth login
flyctl|flyctl auth whoami|flyctl auth login
neonctl|neonctl me|neonctl auth
tigris|tigris whoami|tigris login
gemini|test -f "$HOME/.gemini/oauth_creds.json"|gemini
codex|test -f "$HOME/.codex/auth.json"|codex login
EOF
}
cmd_logins() {
  local name probe login; login_specs | while IFS='|' read -r name probe login; do
    have "$name" || { printf '  ✗ %-8s missing\n' "$name"; continue; }
    if eval "$probe" >/dev/null 2>&1; then printf '  ✔ %-8s logged in\n' "$name"; else printf '  ✗ %-8s run: %s\n' "$name" "$login"; fi
  done
}
run_optional_logins() {
  confirm "Set up CLI logins now?" || return 0
  local name probe login; while IFS='|' read -r name probe login; do
    have "$name" || continue
    eval "$probe" >/dev/null 2>&1 && continue
    confirm "Log into $name now?" && eval "$login" </dev/tty || true
  done < <(login_specs)
}

dns_ok() { getent hosts "${1:-t3.storage.dev}" >/dev/null 2>&1; }
cmd_fix_dns() {
  local host=${1:-t3.storage.dev}; dns_ok "$host" && { ok "$host resolves already."; return 0; }
  warn "$host does not resolve through the current resolver."
  confirm "Replace /etc/resolv.conf with Cloudflare and Google DNS?" || return 1
  [[ -e /etc/resolv.conf && ! -e /etc/resolv.conf.devsys.bak ]] && sudo cp -L /etc/resolv.conf /etc/resolv.conf.devsys.bak || true
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0\n' | sudo tee /etc/resolv.conf >/dev/null
  dns_ok "$host" && ok "$host resolves now." || { err "Still unresolved."; return 1; }
}

tigris_load() { [[ -f $TIGRIS_ENV ]] && . "$TIGRIS_ENV" || return 1; }
tigris_configure() {
  have tigris || { err "tigris is not installed; run devsys user-install."; return 1; }
  local ak sk bucket; ak=$(ask "Tigris Access Key ID" "${TIGRIS_ACCESS_KEY_ID:-}"); sk=$(ask_secret "Tigris Secret Access Key"); bucket=$(ask "Tigris bucket" "${TIGRIS_BUCKET:-}")
  [[ -n $ak && -n $sk && -n $bucket ]] || { err "All Tigris values are required."; return 1; }
  mkdir -p "$CFG_DIR"
  # %q makes each value safe to source back regardless of special characters.
  {
    printf 'TIGRIS_ACCESS_KEY_ID=%q\n' "$ak"
    printf 'TIGRIS_SECRET_ACCESS_KEY=%q\n' "$sk"
    printf 'TIGRIS_BUCKET=%q\n' "$bucket"
    printf 'AWS_ENDPOINT_URL_S3=%q\n' "https://t3.storage.dev"
  } > "$TIGRIS_ENV"
  chmod 600 "$TIGRIS_ENV"
  tigris login credentials --access-key "$ak" --access-secret "$sk"
  tigris buckets create "$bucket" 2>/dev/null || true
  ok "Tigris configured for $bucket."
}
backup_paths=(.claude .codex .gemini .config/gh .fly .config/neonctl .gitconfig .ssh/id_* .ssh/config .zshrc .zprofile .config/devsys)
collect_repos() {
  local output=$1 repo
  : > "$output"
  [[ -d $WORK_DIR ]] || return 0
  while IFS= read -r repo; do
    git -C "$(dirname "$repo")" remote get-url origin 2>/dev/null || true
  done < <(find "$WORK_DIR" -maxdepth 4 -type d -name .git 2>/dev/null) | sed '/^$/d' | sort -u > "$output"
}
cmd_backup() {
  tigris_load || { warn "Tigris is not configured."; tigris_configure || return 1; tigris_load || return 1; }
  local name pass pass2 temp stage entry expanded; name=$(ask "Backup name" "default"); name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9._-'); [[ -n $name ]] || name=default
  pass=$(ask_secret "Encryption passphrase"); pass2=$(ask_secret "Confirm passphrase"); [[ -n $pass && $pass == "$pass2" ]] || { err "Passphrase is empty or does not match."; return 1; }
  temp=$(mktemp -d); trap 'rm -rf "$temp"' RETURN; stage="$temp/stage"; mkdir -p "$stage"
  for entry in "${backup_paths[@]}"; do
    for expanded in "$HOME"/$entry; do
      [[ -e $expanded ]] || continue
      mkdir -p "$stage/$(dirname "${expanded#"$HOME"/}")"
      cp -a "$expanded" "$stage/${expanded#"$HOME"/}"
    done
  done
  mkdir -p "$stage/.config/devsys"
  collect_repos "$stage/.config/devsys/repos.txt"
  local work_rel=${WORK_DIR#"$HOME"/}
  if [[ -d $WORK_DIR && $work_rel != "$WORK_DIR" ]]; then
    tar --exclude='node_modules' -czf "$temp/bundle.tar.gz" -C "$stage" . -C "$HOME" "$work_rel"
  else
    tar --exclude='node_modules' -czf "$temp/bundle.tar.gz" -C "$stage" .
  fi
  DEVSYS_PASS="$pass" openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in "$temp/bundle.tar.gz" -out "$temp/devsys-$name.tar.enc" -pass env:DEVSYS_PASS || { err "Encryption failed."; return 1; }
  tigris cp "t3://$TIGRIS_BUCKET/devsys-$name.tar.enc" "t3://$TIGRIS_BUCKET/devsys-$name.prev.tar.enc" 2>/dev/null || true
  tigris cp "$temp/devsys-$name.tar.enc" "t3://$TIGRIS_BUCKET/devsys-$name.tar.enc"
  ok "Backup uploaded: devsys-$name.tar.enc"
}
cmd_restore() {
  tigris_load || { err "Run devsys reconfigure first."; return 1; }
  local name pass temp; name=$(ask "Backup name" "default"); name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9._-'); [[ -n $name ]] || name=default; pass=$(ask_secret "Decryption passphrase")
  temp=$(mktemp -d); trap 'rm -rf "$temp"' RETURN
  tigris cp "t3://$TIGRIS_BUCKET/devsys-$name.tar.enc" "$temp/bundle.enc"
  DEVSYS_PASS="$pass" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$temp/bundle.enc" -out "$temp/bundle.tar.gz" -pass env:DEVSYS_PASS || { err "Decryption failed (wrong passphrase?)."; return 1; }
  mkdir "$temp/extract"; tar -xzf "$temp/bundle.tar.gz" -C "$temp/extract"
  confirm "Restore these configuration files into $HOME (existing files are overwritten)?" || return 0
  (cd "$temp/extract" && tar -cf - .) | (cd "$HOME" && tar -xpf -)
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  chmod 600 "$HOME"/.ssh/id_* 2>/dev/null || true
  ok "Configuration restored. Open a new shell."
}

cmd_reset() {
  warn "Reset never changes $WORK_DIR."
  confirm "Remove DevSys configuration ($CFG_DIR)?" && rm -rf "$CFG_DIR" && ok "Removed DevSys configuration." || true
  if confirm "Remove per-user AI and CLI authentication files?"; then
    confirm "Confirm removal of .claude, .codex, .gemini, .config/gh, .fly, and .config/neonctl?" && \
      rm -rf "$HOME/.claude" "$HOME/.codex" "$HOME/.gemini" "$HOME/.config/gh" "$HOME/.fly" "$HOME/.config/neonctl" && ok "Authentication files removed." || true
  fi
}

valid_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
cmd_serve() {
  have tailscale || { err "Tailscale missing."; return 1; }; local sub=${1:-}
  if [[ $sub == status ]]; then tailscale serve status; return; fi
  if [[ $sub == off ]]; then valid_port "${2:-}" || { err "Provide a valid port."; return 1; }; sudo tailscale serve --https="$2" off; return; fi
  valid_port "$sub" || { err "Usage: devsys serve <port>|off <port>|status"; return 1; }
  sudo tailscale serve --bg --https="$sub" "http://127.0.0.1:$sub"; tailscale serve status
}

cmd_status() {
  printf '== devsys %s ==\n' "$DEVSYS_VERSION"
  brew_env
  local tool; for tool in brew mise node bun python3 npm gh flyctl tigris claude codex gemini lazygit; do
    if have "$tool"; then printf '  ✔ %-9s %s\n' "$tool" "$("$tool" --version 2>/dev/null | head -1)"; else printf '  ✗ %-9s missing\n' "$tool"; fi
  done
  systemctl is-active --quiet redis-server 2>/dev/null && ok "Redis: active" || warn "Redis: inactive"
  have tailscale && tailscale status 2>/dev/null | head -1 || true
  cmd_logins
}
cmd_update() {
  local tmp; tmp=$(mktemp); trap 'rm -f "${tmp:-}"; trap - RETURN' RETURN
  curl "${CURL_OPTS[@]}" "$GIST_RAW_URL" -o "$tmp"
  bash -n "$tmp" || { err "Downloaded script failed the syntax check; not installing."; return 1; }
  grep -q 'DEVSYS_VERSION=' "$tmp" || { err "Downloaded file does not look like devsys; not installing."; return 1; }
  as_root install -m 0755 "$tmp" "$SELF_PATH"
  ok "Updated $SELF_PATH"
}

install_self() {
  # Root already installed this version during the handoff; skipping avoids a
  # nested sudo prompt, which would deadlock there.
  if [[ -x $SELF_PATH ]] && grep -q "^DEVSYS_VERSION=\"$DEVSYS_VERSION\"$" "$SELF_PATH" 2>/dev/null; then
    return 0
  fi
  # $0 is normally "bash" for a curl|bash invocation, so never use it as the
  # source path. BASH_SOURCE is a real file only when the script was launched
  # from disk; otherwise update downloads the vetted published copy.
  local source=${BASH_SOURCE[0]:-}
  if [[ -n $source && $source != /dev/stdin && -f $source ]] && head -n 1 "$source" | grep -q '^#!'; then
    as_root install -m 0755 "$source" "$SELF_PATH"
  else
    cmd_update
  fi
}

user_install() {
  ensure_not_root
  [[ ${DEVSYS_HANDOFF:-} == 1 ]] || require_tty
  # The toolchain is shared and root-installed; per-user setup is config only.
  [[ -x $BREW_BIN ]] || { err "Shared toolchain is missing; run the installer as root first (it installs once for all users)."; return 1; }
  run_step "Shell configuration" configure_shell
  run_step "AI tool configuration" configure_ai
  install_self || warn "Could not install the devsys command; rerun 'devsys update' later."
  if [[ ${DEVSYS_HANDOFF:-} == 1 ]]; then
    # The handoff is unattended: interactive logins would need a controlling
    # terminal and (for Tailscale) nested sudo, so they happen post-install.
    ok "Done. Log in as $USER and run 'devsys logins' to connect your CLIs."
    return 0
  fi
  confirm "Connect this VM to Tailscale now?" && setup_tailscale || true
  run_optional_logins
  ok "Done. Open a new terminal or run: exec zsh"
}
cmd_install() {
  if is_root; then
    if [[ ${DEVSYS_UNATTENDED:-} == 1 ]]; then
      # cloud-init / scripted path: no TTY exists, so every answer must come
      # from the environment (DEVSYS_USER, DEVSYS_TS_*). Fail fast if the
      # username is missing rather than hanging on a prompt that cannot appear.
      [[ -n ${DEVSYS_USER:-} ]] || { err "DEVSYS_UNATTENDED=1 requires DEVSYS_USER."; return 1; }
    else
      require_tty
    fi
    install_system_stage
    run_step "Shared toolchain owner" ensure_brew_owner
    handoff_toolchain
    run_step "devsys command" cmd_update || warn "Rerun 'devsys update' later."
    local user; user=$(select_dev_user)
    prepare_user_system "$user"
    if [[ -n ${DEVSYS_TS_AUTHKEY:-} ]]; then
      run_step "Tailscale connect" setup_tailscale
    elif [[ ${DEVSYS_UNATTENDED:-} != 1 ]]; then
      confirm "Connect this VM to Tailscale now?" && setup_tailscale || true
    fi
    handoff_to_user "$user"
  else user_install; fi
}
cmd_help() { cat <<EOF
devsys $DEVSYS_VERSION — Ubuntu/Debian Homebrew development VM bootstrap
Usage: devsys [install|system-install|toolchain-install|user-install|brew|npm|mise|ts-login|logins|backup|restore|reconfigure|reset|status|serve|fix-dns|update|help]
  ts-login         Print a Tailscale login link to send to a developer; the
                   VM joins the tailnet under whoever signs in (no admin key).
  install          Root: system + shared toolchain + per-user handoff.
                   Rerun it to add another dev user (toolchain is reused).
  system-install   Root-only OS packages and services.
  user-install     Per-user shell/AI config (toolchain must exist already).
  brew/npm/mise    Manage the shared toolchain as its owner, e.g.
                   devsys brew install deno · devsys mise ls
                   (version pins live in MISE_TOOLS/NPM_CLIS in this script)
  backup/restore   Encrypted Tigris configuration backup and restore.
EOF
}
main() {
  local command=${1:-install}; shift || true
  case "$command" in
    install) cmd_install "$@";; system-install) install_system_stage;; user-install) user_install;;
    toolchain-install) toolchain_install;; brew) cmd_brew "$@";; npm) cmd_npm "$@";; mise) cmd_mise "$@";;
    ts-login) cmd_ts_login;;
    logins) cmd_logins;; backup) cmd_backup;; restore) cmd_restore;; reconfigure) tigris_configure;; reset) cmd_reset;;
    status) cmd_status;; serve) cmd_serve "$@";; fix-dns) cmd_fix_dns "$@";; update) cmd_update;; help|-h|--help) cmd_help;;
    *) err "Unknown command: $command"; cmd_help; return 1;;
  esac
}
main "$@"
