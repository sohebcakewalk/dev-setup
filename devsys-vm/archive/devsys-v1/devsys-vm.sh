#!/usr/bin/env bash
# devsys-vm — one-script VPS bootstrap. https://gist.github.com/<user>/<id>
set -uo pipefail

DEVSYS_VERSION="0.1.0"
CFG_DIR="$HOME/.config/devsys"
# shellcheck disable=SC2034 # consumed by later tasks
WORK_DIR="$HOME/work"
SELF_PATH="/usr/local/bin/devsys"

# ---- logging ----
if [ -t 2 ]; then C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else C_R=; C_G=; C_Y=; C_B=; C_0=; fi
log()  { printf '%s\n' "${C_B}▸${C_0} $*" >&2; }
ok()   { printf '%s\n' "${C_G}✔${C_0} $*" >&2; }
warn() { printf '%s\n' "${C_Y}⚠${C_0} $*" >&2; }
err()  { printf '%s\n' "${C_R}✗${C_0} $*" >&2; }

# ---- tty prompts (work under curl | bash) ----
ask() { # ask "Prompt" "default" -> echoes answer
  local p="$1" d="${2:-}" a
  if [ -n "$d" ]; then printf '%s [%s]: ' "$p" "$d" >&2; else printf '%s: ' "$p" >&2; fi
  read -r a </dev/tty || a=""
  printf '%s' "${a:-$d}"
}
ask_secret() { local p="$1" a; printf '%s: ' "$p" >&2; read -rs a </dev/tty || a=""; printf '\n' >&2; printf '%s' "$a"; }
confirm() { local p="$1" a; printf '%s [y/N]: ' "$p" >&2; read -r a </dev/tty || a=""; [ "$a" = y ] || [ "$a" = Y ]; }

have() { command -v "$1" >/dev/null 2>&1; }

# Back up a file to <file>.devsys.bak before we overwrite it — but only the
# first time (never clobber the user's original backup on a re-run).
backup_once() {
  local f="$1"
  [ -e "$f" ] || return 0
  [ -e "$f.devsys.bak" ] && return 0
  cp -a "$f" "$f.devsys.bak" 2>/dev/null && warn "backed up existing $f -> $f.devsys.bak" || true
}

run_step() { # run_step "Name" function_name [args...]
  local name="$1"; shift
  while true; do
    log "$name"
    if "$@"; then ok "$name"; return 0; fi
    warn "Step failed: $name"
    local c; c=$(ask "  [r]etry / [s]kip / [a]bort" "s")
    case "$c" in r|R) continue;; a|A) err "Aborted."; exit 1;; *) warn "Skipped: $name"; return 0;; esac
  done
}

# ---- privilege + arch ----
if [ "$(id -u)" -eq 0 ]; then SUDO=""; elif have sudo; then SUDO="sudo"; else
  err "Need root or sudo."; exit 1; fi

# shellcheck disable=SC2034 # ARCH consumed by later tasks
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64;;
  aarch64|arm64) ARCH=arm64;;
  *) err "Unsupported arch: $(uname -m)"; exit 1;;
esac

require_apt() { have apt-get || { err "This script targets Ubuntu/Debian (apt-get not found)."; exit 1; }; }

# ---- system packages ----
APT_BASE="git curl wget ca-certificates gnupg lsb-release openssh-client \
iputils-ping dnsutils net-tools rsync unzip build-essential pkg-config \
zsh tmux jq htop ncdu ripgrep fd-find bat eza fzf direnv age openssl \
postgresql-client"

apt_update_once() { [ -n "${_APT_UPDATED:-}" ] && return 0; $SUDO apt-get update -y && _APT_UPDATED=1; }

install_base_packages() {
  require_apt; apt_update_once
  # shellcheck disable=SC2086
  # (env, not a bare "$SUDO DEBIAN_FRONTEND=..." prefix: when SUDO="" (running as root)
  # the empty expansion makes bash stop treating the following VAR=value as an
  # environment-prefix, since that recognition is a parse-time, not runtime, decision.)
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $APT_BASE || return 1
  # devsys-style aliases rely on bat/fd canonical names:
  have batcat && ! have bat && $SUDO ln -sf "$(command -v batcat)" /usr/local/bin/bat || true
  have fdfind && ! have fd && $SUDO ln -sf "$(command -v fdfind)" /usr/local/bin/fd || true
  return 0
}

install_services() {
  require_apt; apt_update_once
  # Redis
  have redis-server || $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server || return 1
  # Tailscale official repo
  if ! have tailscale; then
    local rel; rel="$(lsb_release -cs 2>/dev/null || echo noble)"
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${rel}.noarmor.gpg" \
      | $SUDO tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${rel}.tailscale-keyring.list" \
      | $SUDO tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    $SUDO apt-get update -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale || return 1
  fi
  return 0
}

# ---- language runtimes ----
install_runtimes() {
  # mise
  if ! have mise && [ ! -x "$HOME/.local/bin/mise" ]; then
    curl -fsSL https://mise.run | sh || return 1
  fi
  export PATH="$HOME/.local/bin:$PATH"
  eval "$("$HOME/.local/bin/mise" activate bash)" 2>/dev/null || true
  "$HOME/.local/bin/mise" use --global node@lts || return 1
  "$HOME/.local/bin/mise" use --global python@3.12 || return 1
  eval "$("$HOME/.local/bin/mise" activate bash)" 2>/dev/null || true
  # Bun (guard on the on-disk binary too, so re-runs are a true no-op)
  if ! have bun && [ ! -x "$HOME/.bun/bin/bun" ]; then
    curl -fsSL https://bun.sh/install | bash || return 1
  fi
  export PATH="$HOME/.bun/bin:$PATH"
  # pnpm (via the mise-provided node's npm)
  have pnpm || npm install -g pnpm || "$HOME/.local/bin/mise" exec node@lts -- npm install -g pnpm || return 1
  return 0
}

# ---- CLI tools ----
npm_g() { npm install -g "$@" || "$HOME/.local/bin/mise" exec node@lts -- npm install -g "$@"; }

install_clis() {
  export PATH="$HOME/.local/bin:$PATH"; eval "$("$HOME/.local/bin/mise" activate bash)" 2>/dev/null || true

  # gh (GitHub CLI) via official apt repo
  if ! have gh; then
    $SUDO mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    $SUDO apt-get update -y && $SUDO apt-get install -y gh || return 1
  fi

  # flyctl
  have fly || have flyctl || { curl -fsSL https://fly.io/install.sh | sh || return 1; }

  # npm-based CLIs
  have neonctl   || npm_g neonctl            || return 1
  have tigris    || npm_g @tigrisdata/cli    || return 1
  have claude    || npm_g @anthropic-ai/claude-code || return 1
  have gemini    || npm_g @google/gemini-cli || return 1
  have codex     || npm_g @openai/codex      || return 1
  have opencode  || npm_g opencode-ai        || return 1
  have ob        || npm_g obsidian-headless  || true   # non-fatal

  # lazygit (latest release)
  if ! have lazygit; then
    local lv tgz larch
    larch=$([ "$ARCH" = arm64 ] && echo arm64 || echo x86_64)
    lv=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+') || true
    if [ -n "${lv:-}" ]; then
      tgz="/tmp/lazygit.tgz"
      # shellcheck disable=SC2015 # no true if/else pitfall here: each step (curl/tar/install)
      # only ever returns 0 on success, so `warn` fires iff any step in the chain failed.
      curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${lv}/lazygit_${lv}_Linux_${larch}.tar.gz" -o "$tgz" \
        && tar -xzf "$tgz" -C /tmp lazygit \
        && $SUDO install -m 0755 /tmp/lazygit /usr/local/bin/lazygit || warn "lazygit install skipped"
    else
      warn "lazygit: could not resolve latest release tag; skipped"
    fi
  fi

  # glow (latest release) — no Ubuntu 24.04 apt package exists, so this is
  # installed the same way as lazygit above: GitHub release, not APT_BASE.
  if ! have glow; then
    local gv gtgz gdir garch gbin
    garch=$([ "$ARCH" = arm64 ] && echo arm64 || echo x86_64)
    gv=$(curl -fsSL https://api.github.com/repos/charmbracelet/glow/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+') || true
    if [ -n "${gv:-}" ]; then
      gtgz="/tmp/glow.tgz"; gdir="/tmp/glow-extract"
      rm -rf "$gdir"; mkdir -p "$gdir"
      # shellcheck disable=SC2015 # no true if/else pitfall here: each step (curl/tar/
      # find/install) only ever returns 0 on success, so `warn` fires iff any step failed.
      curl -fsSL "https://github.com/charmbracelet/glow/releases/download/v${gv}/glow_${gv}_Linux_${garch}.tar.gz" -o "$gtgz" \
        && tar -xzf "$gtgz" -C "$gdir" \
        && gbin=$(find "$gdir" -type f -name glow | head -1) \
        && [ -n "$gbin" ] \
        && $SUDO install -m 0755 "$gbin" /usr/local/bin/glow || warn "glow install skipped"
      rm -rf "$gdir" "$gtgz"
    else
      warn "glow: could not resolve latest release tag; skipped"
    fi
  fi

  # starship prompt
  have starship || { curl -fsSL https://starship.rs/install.sh | $SUDO sh -s -- -y || warn "starship skipped"; }
  return 0
}

# ---- self-install ----
self_install() {
  local src="${BASH_SOURCE[0]:-}"
  if [ -n "$src" ] && [ -f "$src" ]; then
    [ "$src" = "$SELF_PATH" ] && return 0   # already the installed copy
    $SUDO install -m 0755 "$src" "$SELF_PATH" && ok "Installed devsys -> $SELF_PATH"
    return 0
  fi
  # Piped via curl|bash: no source file on disk — fetch the script from the gist
  # so the permanent `devsys` command still gets installed on first run.
  local tmp; tmp="$(mktemp)" || return 0
  if curl -fsSL "$GIST_RAW_URL" -o "$tmp" && bash -n "$tmp" 2>/dev/null; then
    $SUDO install -m 0755 "$tmp" "$SELF_PATH" && ok "Installed devsys -> $SELF_PATH"
  else
    warn "Could not auto-install the 'devsys' command to $SELF_PATH; copy it there manually if needed."
  fi
  rm -f "$tmp"
}

# ---- shell configuration ----
configure_shell() {
  mkdir -p "$WORK_DIR"

  backup_once "$HOME/.zshenv"
  cat > "$HOME/.zshenv" <<'EOF'
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.fly/bin:$PATH"
export EDITOR=vim
EOF

  backup_once "$HOME/.zshrc"
  cat > "$HOME/.zshrc" <<'EOF'
# --- devsys-vm managed ---
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.fly/bin:$PATH"
command -v mise     >/dev/null && eval "$(mise activate zsh)"
command -v direnv   >/dev/null && eval "$(direnv hook zsh)"
command -v starship >/dev/null && eval "$(starship init zsh)"
alias ls='eza'  ll='eza -la --git'  tree='eza --tree'
alias cat='bat --paging=never'  lg='lazygit'
alias gemini='gemini --yolo'
alias codex='codex --dangerously-bypass-approvals-and-sandbox'
cd "$HOME/work" 2>/dev/null || true
# --- end devsys-vm ---
EOF

  # /etc/tmux.conf is root-owned; back it up with $SUDO before the tee overwrite.
  [ -e /etc/tmux.conf ] && [ ! -e /etc/tmux.conf.devsys.bak ] \
    && { $SUDO cp -a /etc/tmux.conf /etc/tmux.conf.devsys.bak 2>/dev/null \
         && warn "backed up existing /etc/tmux.conf -> /etc/tmux.conf.devsys.bak" || true; }
  cat <<'EOF' | $SUDO tee /etc/tmux.conf >/dev/null
set -g mouse on
EOF

  # default shell -> zsh
  if have zsh && [ "${SHELL:-}" != "$(command -v zsh)" ]; then
    $SUDO chsh -s "$(command -v zsh)" "$(id -un)" 2>/dev/null || warn "Could not chsh to zsh"
  fi
  return 0
}

# ---- AI zero-prompt configs ----
configure_ai() {
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.gemini"

  # Claude Code — merge into existing settings.json if present, else create.
  local cs="$HOME/.claude/settings.json"
  local tmp
  if have jq && [ -s "$cs" ]; then
    tmp=$(mktemp); jq '.defaultMode="bypassPermissions" | .env.IS_SANDBOX="1"' "$cs" > "$tmp" && mv "$tmp" "$cs"
  else
    printf '%s\n' '{"defaultMode":"bypassPermissions","env":{"IS_SANDBOX":"1"}}' > "$cs"
  fi

  backup_once "$HOME/.codex/config.toml"
  cat > "$HOME/.codex/config.toml" <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"
EOF

  backup_once "$HOME/.gemini/settings.json"
  printf '%s\n' '{"general":{"defaultApprovalMode":"auto_edit"}}' > "$HOME/.gemini/settings.json"
  return 0
}

# ---- boot persistence ----
# Opt-in boot-time DNS reapply (see cmd_fix_dns): installs an INERT systemd unit
# that only does anything if $CFG_DIR/dns.env sets DEVSYS_DNS_FIX=1. Boot logic
# lives in a plain sh script (not inline in the unit) so there's no systemd
# escaping to get wrong.
_install_dns_boot_unit() {
  have systemctl || return 0
  # Boot reapply logic lives in a plain script (no systemd escaping headaches).
  $SUDO mkdir -p /usr/local/lib
  cat <<EOF | $SUDO tee /usr/local/lib/devsys-dns-reapply.sh >/dev/null
#!/bin/sh
# Reapply a public DNS resolver at boot IF opted in AND the Tigris endpoint can't resolve.
[ -f ${CFG_DIR}/dns.env ] && . ${CFG_DIR}/dns.env
[ "\${DEVSYS_DNS_FIX:-0}" = 1 ] || exit 0
getent hosts t3.storage.dev >/dev/null 2>&1 && exit 0
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0\n' > /etc/resolv.conf.devsys.tmp \
  && mv /etc/resolv.conf.devsys.tmp /etc/resolv.conf
EOF
  $SUDO chmod 0755 /usr/local/lib/devsys-dns-reapply.sh
  cat <<EOF | $SUDO tee /etc/systemd/system/devsys-dns.service >/dev/null
[Unit]
Description=devsys-vm: reapply public DNS resolver at boot if endpoint unresolvable (opt-in)
DefaultDependencies=no
After=network-pre.target
Before=network-online.target tailscaled.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/devsys-dns-reapply.sh
[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable devsys-dns.service 2>/dev/null || warn "devsys-dns enable failed"
}

setup_boot_persistence() {
  if ! have systemctl; then warn "No systemd here; skipping boot units (fine in a container)."; return 0; fi

  $SUDO systemctl enable --now tailscaled 2>/dev/null || warn "tailscaled enable failed"
  $SUDO systemctl enable --now redis-server 2>/dev/null || warn "redis enable failed"

  # NOTE: this heredoc is intentionally UNQUOTED (<<EOF, not <<'EOF') so that
  # $CFG_DIR interpolates to the actual install-time config dir (matches
  # wherever setup_tailscale() wrote tailscale.env — /root/... for a root
  # install, /home/<user>/... for a sudo-capable non-root install). Every
  # other literal '$' in the ExecStart line is backslash-escaped so it
  # survives heredoc expansion and lands in the unit file as a literal
  # '$${TS_ACCEPT_DNS:-false}' for systemd to unescape to '${...}' for dash.
  cat <<EOF | $SUDO tee /etc/systemd/system/devsys-boot.service >/dev/null
[Unit]
Description=devsys-vm boot: re-assert tailscale up
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
Type=oneshot
# Re-assert from persisted state; --ssh is idempotent. Never fail the boot.
ExecStart=/bin/sh -c '[ -f ${CFG_DIR}/tailscale.env ] && . ${CFG_DIR}/tailscale.env; tailscale up --ssh=true --accept-dns=\$\${TS_ACCEPT_DNS:-false} --accept-routes=true || true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable devsys-boot.service 2>/dev/null || warn "devsys-boot enable failed"

  _install_dns_boot_unit
  return 0
}

# ---- tailscale connect ----
tailscale_connected() { tailscale status --json 2>/dev/null | grep -q '"BackendState":\s*"Running"'; }

setup_tailscale() {
  have tailscale || { warn "tailscale not installed; skipping."; return 0; }
  local reauth=1
  if tailscale_connected; then
    ok "Tailscale already connected ($(tailscale status 2>/dev/null | head -1))"
    confirm "Re-authenticate anyway (change hostname / new auth key)?" || reauth=0
  fi
  local ts_dns=false
  if confirm "Route this VM's DNS through your tailnet (MagicDNS)? Recommended No — Yes can break outbound DNS (Tigris/npm) on restrictive tailnets"; then
    ts_dns=true
  fi
  mkdir -p "$CFG_DIR"; printf 'TS_ACCEPT_DNS=%s\n' "$ts_dns" > "$CFG_DIR/tailscale.env"
  if [ "$reauth" = 0 ]; then
    if $SUDO tailscale set --accept-dns="$ts_dns" 2>/dev/null; then
      ok "Applied --accept-dns=$ts_dns to the running node."
    else
      warn "Could not apply --accept-dns via 'tailscale set'."
    fi
    return 0
  fi
  local host; host=$(ask "Tailscale hostname for this machine" "$(hostname -s 2>/dev/null || echo devsys)")
  echo "  1) Paste a reusable auth key (recommended for headless)"
  echo "  2) Interactive browser login (prints a URL)"
  local m; m=$(ask "Choose" "1")
  if [ "$m" = 1 ]; then
    local key; key=$(ask_secret "TS_AUTHKEY (tskey-…)")
    [ -n "$key" ] || { warn "No key entered; skipping."; return 0; }
    $SUDO tailscale up --authkey="$key" --hostname="$host" --ssh=true --accept-dns="$ts_dns" --accept-routes=true || return 1
  else
    $SUDO tailscale up --hostname="$host" --ssh=true --accept-dns="$ts_dns" --accept-routes=true || return 1
  fi
  ok "Tailscale: $(tailscale status 2>/dev/null | head -1)"
  return 0
}

# ---- optional CLI logins ----
# name|status-probe|login-command
login_specs() {
  cat <<'EOF'
claude|claude auth status >/dev/null 2>&1; test $? -eq 0 -o -f "$HOME/.claude/.credentials.json"|claude  (then type /login)
gh|gh auth status >/dev/null 2>&1|gh auth login
fly|fly auth whoami >/dev/null 2>&1|fly auth login
neonctl|neonctl me >/dev/null 2>&1|neonctl auth
tigris|tigris whoami >/dev/null 2>&1|tigris login
gemini|test -f "$HOME/.gemini/oauth_creds.json" -o -n "${GEMINI_API_KEY:-}"|gemini  (then /auth)
codex|test -f "$HOME/.codex/auth.json"|codex login
EOF
}

_probe() {
  # shellcheck disable=SC2294 # trusted: probe strings are our own literals from login_specs, not user input
  eval "$1" >/dev/null 2>&1
}

run_optional_logins() {
  log "Optional CLI logins (all skippable; run 'devsys logins' any time)."
  local skip_all=0 name probe cmdline base
  while IFS='|' read -r name probe cmdline; do
    [ "$skip_all" = 1 ] && continue
    base="${name%% *}"
    have "$base" || continue
    if _probe "$probe"; then ok "$name already logged in"; continue; fi
    local a; a=$(ask "Log into $name now? (y / n / A=skip all)" "n")
    case "$a" in
      # claude/gemini's cmdline is a human hint ("claude  (then type /login)"), not
      # runnable shell syntax; strip the trailing "(...)" so sh -c gets just the CLI.
      y|Y) sh -c "${cmdline%%(*}" </dev/tty || warn "$name login skipped/failed";;
      A)   skip_all=1;;
      *)   : ;;
    esac
  done < <(login_specs)
  return 0
}

# ---- tigris backup ----
TIGRIS_ENV="$CFG_DIR/tigris.env"
# Encrypted bundle uses openssl, not age: see cmd_backup for why.
# Backups are named: _bundle_key/_bundle_prev_key map a sanitized name to its
# own pair of remote objects (current + one rotated .prev) so multiple named
# snapshots can coexist in the same bucket without clobbering each other.
_sanitize_name() { local n; n="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-')"; [ -n "$n" ] && printf '%s' "$n" || printf 'default'; }
_bundle_key()      { printf 'devsys-%s.tar.enc' "$1"; }
_bundle_prev_key() { printf 'devsys-%s.prev.tar.enc' "$1"; }
BACKUP_PATHS=(
  ".claude" ".codex" ".gemini" ".config/gh" ".fly/config.yml" ".config/neonctl"
  ".gitconfig" ".ssh/id_*" ".ssh/config" ".zshrc" ".zshenv"
  ".config/devsys/tigris.env"
)

# Human size of a path (file or dir); empty string on failure — callers fall
# back to "?" so a missing/unreadable `du` never breaks the manifest output.
_du() { du -sh "$1" 2>/dev/null | cut -f1; }
# _barline k total label size -> prints one fixed-width [#---] progress line.
# Plain per-line output (no carriage-return redraw) so it stays legible under
# `curl | bash` and in non-tty logs. total=0 is guarded (no divide-by-zero).
_barline() {
  local k="$1" t="$2" label="$3" size="$4" w=20 f i bar=''
  [ "$t" -gt 0 ] && f=$(( k * w / t )) || f=0
  i=0; while [ "$i" -lt "$w" ]; do [ "$i" -lt "$f" ] && bar="$bar#" || bar="$bar-"; i=$((i+1)); done
  printf '  [%s] %d/%d  %s (%s)\n' "$bar" "$k" "$t" "$label" "${size:-?}" >&2
}

# ---- DNS diagnostics ----
# System resolver can resolve this host?
_dns_ok_system() { getent hosts "$1" >/dev/null 2>&1; }
# A specific public resolver can resolve it? (count only ANSWER Address lines, not the "Address: <server>#53" line)
_dns_ok_via() { have nslookup || return 2; nslookup "$1" "$2" 2>/dev/null | awk '/^Address: /{if ($2 !~ /#/) f=1} END{exit !f}'; }

# Print a tailored hint when $1 (host) can't be reached.
dns_hint() {
  local host="$1"
  if _dns_ok_system "$host"; then
    warn "DNS resolves $host — the failure looks like network/connectivity, not DNS."
    return 0
  fi
  if grep -q '100\.100\.100\.100' /etc/resolv.conf 2>/dev/null; then
    warn "Tailscale MagicDNS is handling DNS and can't resolve $host."
    warn "Fix: sudo tailscale set --accept-dns=false    (or run: devsys fix-dns)"
  elif ! have nslookup; then
    warn "Your system resolver can't resolve $host. Run  devsys fix-dns  to switch to a public resolver."
  elif _dns_ok_via "$host" 1.1.1.1; then
    warn "Your system DNS resolver can't resolve $host, but public DNS (1.1.1.1) can."
    warn "Fix: run  devsys fix-dns   to point this VM at a public resolver."
  else
    warn "$host isn't resolving via public DNS either — DNS may be blocked on this network."
    warn "Try another network / DNS-over-HTTPS, or the alt endpoint fly.storage.tigris.dev."
  fi
}

# Fail early with a clear DNS hint if the Tigris S3 endpoint isn't reachable.
tigris_reachable() {
  curl -sS -m 8 -o /dev/null "https://t3.storage.dev" 2>/dev/null
  local rc=$?
  if [ "$rc" -eq 6 ] || [ "$rc" -eq 7 ]; then
    err "Cannot reach Tigris endpoint t3.storage.dev (curl exit $rc — DNS/connectivity)."
    dns_hint "t3.storage.dev"
    return 1
  fi
  return 0
}

# Returns 0 if the current tigris credentials can WRITE to the bucket.
tigris_writable() { # tigris_writable <bucket>
  local bk="$1" ptmp
  ptmp="$(mktemp)" || return 1
  printf 'devsys-writetest' > "$ptmp"
  if tigris cp "$ptmp" "t3://$bk/.devsys-writetest" >/dev/null 2>&1; then
    # Same delete pattern as cmd_reset: top-level `tigris rm -y` first, falling
    # back to the low-level `tigris objects delete -y <bucket> <key>` form.
    tigris rm -y "t3://$bk/.devsys-writetest" >/dev/null 2>&1 \
      || tigris objects delete -y "$bk" ".devsys-writetest" >/dev/null 2>&1 || true
    rm -f "$ptmp"; return 0
  fi
  rm -f "$ptmp"; return 1
}

tigris_configure() {
  have tigris || { err "tigris CLI not installed."; return 1; }
  local ak sk bk
  # shellcheck disable=SC1090 # TIGRIS_ENV is our own generated config, not user input
  if [ -f "$TIGRIS_ENV" ]; then . "$TIGRIS_ENV"; fi
  ak=$(ask "Tigris Access Key ID" "${TIGRIS_ACCESS_KEY_ID:-}")
  sk=$(ask_secret "Tigris Secret Access Key")
  [ -n "$sk" ] || sk="${TIGRIS_SECRET_ACCESS_KEY:-}"
  bk=$(ask "Tigris bucket name" "${TIGRIS_BUCKET:-}")
  [ -n "$ak" ] && [ -n "$sk" ] && [ -n "$bk" ] || { err "All three values required."; return 1; }

  umask 077
  cat > "$TIGRIS_ENV" <<EOF
TIGRIS_ACCESS_KEY_ID=$ak
TIGRIS_SECRET_ACCESS_KEY=$sk
TIGRIS_BUCKET=$bk
AWS_ENDPOINT_URL_S3=https://t3.storage.dev
EOF
  chmod 600 "$TIGRIS_ENV"

  tigris login credentials --access-key "$ak" --access-secret "$sk" || return 1
  tigris_reachable || return 1
  tigris buckets list 2>/dev/null | grep -qw "$bk" || tigris buckets create "$bk" || warn "Bucket create failed (may already exist elsewhere)"

  tigris_reachable || return 1
  if tigris_writable "$bk"; then
    ok "Write access to '$bk' confirmed."
  else
    err "This access key cannot WRITE to bucket '$bk' (read-only key, or the bucket is owned by another account)."
    warn "Create a read-write (Editor/Admin) access key in the Tigris console, then run: devsys reconfigure"
    return 1
  fi

  ok "Tigris configured (bucket: $bk)"
  return 0
}

collect_repos() {
  local out="$1"; : > "$out"
  [ -d "$WORK_DIR" ] || return 0
  # find git repos up to 4 levels deep, record origin URL
  while IFS= read -r gitdir; do
    local repo; repo="$(dirname "$gitdir")"
    local url; url="$(git -C "$repo" remote get-url origin 2>/dev/null)" || continue
    [ -n "$url" ] && printf '%s\n' "$url" >> "$out"
  done < <(find "$WORK_DIR" -maxdepth 4 -type d -name .git 2>/dev/null)
  sort -u -o "$out" "$out" 2>/dev/null || true
}

# ---- command stubs (filled by later tasks) ----
tigris_prereq_note() {
  warn "Restore needs the tigris CLI. Installing runtimes + tigris first…"
  run_step "Runtimes for restore"   install_runtimes
  run_step "tigris CLI for restore" install_clis
}
cmd_install() {
  log "devsys-vm installer $DEVSYS_VERSION (Ubuntu/Debian, $ARCH)"
  require_apt
  self_install

  # Offer restore-first if this looks like a fresh machine
  if [ ! -f "$TIGRIS_ENV" ] && ! have claude && confirm "Restore an existing setup from Tigris first?"; then
    tigris_prereq_note
    cmd_restore || warn "Restore skipped/failed; continuing with fresh install."
  fi

  run_step "System packages & tools"     install_base_packages
  run_step "Services (redis, tailscale)" install_services
  run_step "Language runtimes (mise)"    install_runtimes
  run_step "CLI tools"                   install_clis
  run_step "Shell configuration"         configure_shell
  run_step "AI zero-prompt configs"      configure_ai
  run_step "Boot persistence"            setup_boot_persistence
  run_step "Tailscale"                   setup_tailscale

  run_optional_logins

  if confirm "Set up Tigris backup now?"; then
    tigris_configure && { confirm "Run first backup now?" && cmd_backup; }
  fi

  echo >&2; ok "Done. Open a new shell (zsh) or run: exec zsh"
  log  "Handy: 'devsys logins' (auth status), 'devsys backup', 'devsys status'."
  return 0
}
cmd_logins()  {
  printf '%s\n' "CLI login status (✔ = ready, ✗ = not logged in):" >&2
  local name probe cmdline
  login_specs | while IFS='|' read -r name probe cmdline; do
    have "${name%% *}" || { printf '  %s  %-9s not installed\n' "✗" "$name" >&2; continue; }
    if _probe "$probe"; then printf '  \033[32m✔\033[0m %-9s logged in\n' "$name" >&2
    else printf '  \033[31m✗\033[0m %-9s  → %s\n' "$name" "$cmdline" >&2; fi
  done
}
cmd_backup() {
  [ -f "$TIGRIS_ENV" ] || { warn "Tigris not configured; running setup."; tigris_configure || return 1; }
  # shellcheck disable=SC1090 # TIGRIS_ENV is our own generated config, not user input
  . "$TIGRIS_ENV"
  have tigris  || { err "tigris CLI missing."; return 1; }
  have openssl || { err "openssl missing (apt install openssl)."; return 1; }
  tigris_reachable || return 1
  tigris_writable "$TIGRIS_BUCKET" || {
    err "Cannot write to Tigris bucket '$TIGRIS_BUCKET' — access key is read-only or the bucket is owned by another account."
    warn "Fix: create a read-write key in the Tigris console, then run: devsys reconfigure"
    return 1
  }

  local name; name=$(_sanitize_name "$(ask "Backup name" "default")")
  local key; key=$(_bundle_key "$name")
  local prevkey; prevkey=$(_bundle_prev_key "$name")

  local work; work="$(mktemp -d)" || return 1
  # Self-clearing: fires once when cmd_backup itself returns (covers every exit
  # path below), then unregisters itself so it can't fire again — with no
  # `set -T`/functrace in this script, a plain RETURN trap set here is never
  # invoked by nested functions' returns, but it DOES stay registered after
  # cmd_backup returns and would otherwise fire again (with $work out of scope,
  # i.e. an unbound-variable crash under `set -u`) when main() returns.
  trap 'rm -rf "$work"; trap - RETURN' RETURN

  # Stage everything under $work/stage mirroring $HOME layout, then tar once.
  local stage="$work/stage"; mkdir -p "$stage"

  # First pass: expand BACKUP_PATHS globs, keep only the paths that actually
  # exist, so the progress bar below knows the true total up front.
  local p expanded rel
  local -a stage_manifest=()
  for p in "${BACKUP_PATHS[@]}"; do
    # shellcheck disable=SC2086  # intentional glob expansion of patterns like .ssh/id_*
    for expanded in "$HOME/"$p; do
      [ -e "$expanded" ] || continue
      stage_manifest+=("${expanded#"$HOME"/}")
    done
  done
  local total="${#stage_manifest[@]}"

  # Second pass: stage each item, printing a bar + counter + size as we go.
  local k=0
  for rel in "${stage_manifest[@]}"; do
    k=$((k+1))
    mkdir -p "$stage/$(dirname "$rel")"
    cp -a "$HOME/$rel" "$stage/$rel"
    _barline "$k" "$total" "$rel" "$(_du "$HOME/$rel")"
  done

  # repo manifest goes into the same config dir so restore finds it predictably
  mkdir -p "$stage/.config/devsys"
  collect_repos "$stage/.config/devsys/repos.txt"
  log "Staged $total item(s), ~$(_du "$stage") uncompressed"

  # ~/work is archived straight out of $HOME by the tar below (not staged/copied
  # first) so a large work tree never doubles disk usage under $work/stage.
  # node_modules is excluded from the archive only — nothing on disk is touched.
  local _WORK_INCLUDED=0
  if [ -d "$WORK_DIR" ] && [ -n "$(ls -A "$WORK_DIR" 2>/dev/null)" ]; then
    log "Including ~/work (excluding node_modules): $(du -sh --exclude=node_modules "$WORK_DIR" 2>/dev/null | cut -f1)"
    _WORK_INCLUDED=1
  fi

  local pass pass2
  pass=$(ask_secret "Encryption passphrase"); pass2=$(ask_secret "Confirm passphrase")
  [ -n "$pass" ] && [ "$pass" = "$pass2" ] || { err "Passphrase empty or mismatch."; return 1; }

  log "Creating encrypted bundle…"
  # GNU tar's --exclude matches a bare (no-slash) pattern against EVERY path
  # component of every candidate entry, not just the top-level one — so a
  # single --exclude='node_modules' already drops node_modules dirs at any
  # depth (repoA/node_modules, repoA/sub/node_modules, ...). VERIFIED
  # in-container with a nested node_modules tree (see backup-work-report.md);
  # a second --exclude='*/node_modules' was tested too and excluded nothing
  # extra, so it's omitted here to keep the invocation minimal.
  if [ "$_WORK_INCLUDED" = 1 ]; then
    tar -czf "$work/bundle.tar.gz" --exclude='node_modules' \
      -C "$stage" . -C "$HOME" work || return 1
  else
    tar -czf "$work/bundle.tar.gz" --exclude='node_modules' \
      -C "$stage" . || return 1
  fi
  # Passphrase-based symmetric encryption via openssl. VERIFIED: apt's `age` (Go
  # implementation) always demands /dev/tty for -p and cannot take a passphrase
  # non-interactively (no AGE_PASSPHRASE support, no stdin fallback), so it is
  # unusable in this non-interactive backup flow. openssl is fully non-interactive
  # and ships everywhere; restore (Task 10) MUST use the identical invocation.
  # DEVSYS_PASS is set only in this command's environment, never on argv/-k.
  DEVSYS_PASS="$pass" openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -in "$work/bundle.tar.gz" -out "$work/$key" -pass env:DEVSYS_PASS || return 1
  log "Encrypted bundle: $(_du "$work/$key") — uploading as $key"

  # rotate previous, upload (silent — no prompt; the one prior named bundle is
  # kept as .prev, matching this command's existing rotation behavior)
  tigris cp "t3://$TIGRIS_BUCKET/$key" "t3://$TIGRIS_BUCKET/$prevkey" 2>/dev/null || true
  if ! tigris cp "$work/$key" "t3://$TIGRIS_BUCKET/$key"; then
    err "Backup upload FAILED — the bundle was built but not uploaded."
    warn "Check write permissions (devsys reconfigure) or DNS (devsys fix-dns), then retry: devsys backup"
    return 1
  fi

  printf '%s @ %s\n' "$name" "$(date -u +%FT%TZ)" > "$CFG_DIR/last-backup"
  ok "Backup uploaded to t3://$TIGRIS_BUCKET/$key"
  return 0
}
cmd_restore() {
  [ -f "$TIGRIS_ENV" ] || { warn "Tigris not configured; running setup."; tigris_configure || return 1; }
  # shellcheck disable=SC1090 # TIGRIS_ENV is our own generated config, not user input
  . "$TIGRIS_ENV"
  have tigris  || { err "tigris CLI missing."; return 1; }
  have openssl || { err "openssl missing (apt install openssl)."; return 1; }
  tigris_reachable || return 1

  # Best-effort: list available named backups so the user can see their
  # choices before typing a name. Not every tigris CLI/creds combo supports
  # listing, so a failure here is silent — just skip straight to the prompt.
  local available
  available=$(tigris ls "t3://$TIGRIS_BUCKET/" 2>/dev/null \
    | grep -oE 'devsys-[A-Za-z0-9._-]+\.tar\.enc' | grep -v '\.prev\.' | sort -u) || available=""
  if [ -n "$available" ]; then
    log "Available backups: $(printf '%s' "$available" | sed -E 's/^devsys-//; s/\.tar\.enc$//' | tr '\n' ' ')"
  fi

  local name; name=$(_sanitize_name "$(ask "Backup name to restore" "default")")
  local key; key=$(_bundle_key "$name")

  local work; work="$(mktemp -d)" || return 1
  # Self-clearing: fires once when cmd_restore itself returns (covers every exit
  # path below), then unregisters itself so it can't fire again — with no
  # `set -T`/functrace in this script, a plain RETURN trap set here is never
  # invoked by nested functions' returns, but it DOES stay registered after
  # cmd_restore returns and would otherwise fire again (with $work out of scope,
  # i.e. an unbound-variable crash under `set -u`) when main() returns.
  trap 'rm -rf "$work"; trap - RETURN' RETURN

  log "Downloading bundle…"
  tigris cp "t3://$TIGRIS_BUCKET/$key" "$work/$key" || { err "Download failed (no bundle?)."; return 1; }

  local pass
  pass=$(ask_secret "Decryption passphrase")
  # Same openssl invocation as cmd_backup, inverted (-d). DEVSYS_PASS is set only
  # in this command's environment, never on argv/-k. A wrong passphrase makes
  # openssl exit nonzero (no partial output survives on failure).
  DEVSYS_PASS="$pass" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$work/$key" -out "$work/bundle.tar.gz" -pass env:DEVSYS_PASS 2>/dev/null \
    || { err "Decrypt failed (wrong passphrase?)."; return 1; }

  mkdir -p "$work/extract"
  tar -xzf "$work/bundle.tar.gz" -C "$work/extract" || return 1

  # Copy files into $HOME, asking before clobbering a local file that is NEWER
  # than the backup's copy. Process-substitution (not a `cmd | while` pipe) keeps
  # this loop in cmd_restore's own shell, so `local` here is unambiguous.
  #
  # Compare whole-second epoch mtimes rather than bash's nanosecond-aware `-nt`:
  # GNU tar's default archive format only stores 1-second mtime resolution, so
  # an UNMODIFIED file's original (sub-second-precise) mtime is spuriously
  # "-nt" its own tar-round-tripped copy whenever it has a nonzero fractional
  # second — which is true for nearly every real file. That false positive
  # would make this guard nag on almost every restored file. `stat -c %Y`
  # (whole seconds) sidesteps it while still catching genuine newer-by->=1s edits.
  local rel src dst dst_m src_m
  while IFS= read -r -d '' rel; do
    src="$work/extract/${rel#./}"
    dst="$HOME/${rel#./}"
    if [ -e "$dst" ]; then
      dst_m=$(stat -c %Y "$dst" 2>/dev/null || echo 0)
      src_m=$(stat -c %Y "$src" 2>/dev/null || echo 0)
      if [ "$dst_m" -gt "$src_m" ]; then
        confirm "Local $dst is newer than backup — overwrite?" || { warn "kept local $dst"; continue; }
      fi
    fi
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
  done < <(cd "$work/extract" && find . -type f -print0)

  # shellcheck disable=SC2086 # intentional glob expansion, mirrors BACKUP_PATHS' .ssh/id_*
  chmod 600 "$HOME"/.ssh/id_* 2>/dev/null || true
  chmod 600 "$TIGRIS_ENV" 2>/dev/null || true
  ok "Config restored."

  # Offer to re-clone repos recorded in the backup's manifest.
  local manifest="$HOME/.config/devsys/repos.txt"
  if [ -s "$manifest" ] && confirm "Re-clone $(wc -l < "$manifest") repo(s) into $WORK_DIR?"; then
    mkdir -p "$WORK_DIR"
    local url name
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      name="$(basename "${url%.git}")"
      if [ -d "$WORK_DIR/$name" ]; then
        ok "exists: $name"
      else
        log "cloning $url"
        git -C "$WORK_DIR" clone "$url" || warn "clone failed: $url"
      fi
    done < "$manifest"
  fi
  return 0
}
cmd_reconfigure() { tigris_configure; }
cmd_status() {
  printf '== devsys %s ==\n' "$DEVSYS_VERSION" >&2
  if have tailscale; then
    if tailscale_connected; then ok "Tailscale: $(tailscale status 2>/dev/null | head -1)"
    else warn "Tailscale: not connected (run: devsys install, or tailscale up --ssh)"; fi
  else warn "Tailscale not installed"; fi
  if have systemctl; then
    # shellcheck disable=SC2015 # no true if/else pitfall here: `ok` (a plain printf)
    # always returns 0, so `warn` only ever runs when the `is-active` check itself failed.
    systemctl is-active --quiet redis-server && ok "redis: active" || warn "redis: inactive"
  fi
  local t v
  # openssl is included: cmd_backup/cmd_restore depend on it for the encrypted bundle.
  for t in node python bun pnpm gh fly neonctl tigris claude gemini codex lazygit starship age openssl; do
    if have "$t"; then
      # openssl has no --version flag (it prints "Invalid command" on stderr and
      # nothing useful on stdout); its own subcommand is `openssl version`.
      if [ "$t" = openssl ]; then v="$(openssl version 2>/dev/null)"; else v="$("$t" --version 2>/dev/null | head -1)"; fi
      printf '  ✔ %-9s %s\n' "$t" "${v:-unknown}" >&2
    else printf '  ✗ %-9s (missing)\n' "$t" >&2; fi
  done
  if [ -f "$CFG_DIR/last-backup" ]; then ok "Last backup: $(cat "$CFG_DIR/last-backup")"
  else warn "No backup recorded"; fi
  echo >&2; cmd_logins
  return 0
}
cmd_fix_dns() {
  local host="${1:-t3.storage.dev}"
  log "Diagnosing DNS for $host …"

  if _dns_ok_system "$host"; then
    ok "$host already resolves via the system resolver — nothing to fix."
    return 0
  fi

  # If Tailscale MagicDNS is intercepting DNS, turning it off is the clean fix.
  if have tailscale && grep -q '100\.100\.100\.100' /etc/resolv.conf 2>/dev/null; then
    log "Tailscale MagicDNS is handling DNS; disabling accept-dns on this node…"
    $SUDO tailscale set --accept-dns=false 2>/dev/null || warn "tailscale set failed"
    sleep 1
    if _dns_ok_system "$host"; then ok "Resolved after disabling MagicDNS."; return 0; fi
    warn "Still unresolved after disabling MagicDNS; will set a public resolver."
  fi

  # Ensure we can test a public resolver (nslookup ships in dnsutils; usually already present).
  have nslookup || $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils >/dev/null 2>&1 || true
  if have nslookup; then
    if ! _dns_ok_via "$host" 1.1.1.1; then
      err "$host does not resolve via 1.1.1.1 either — not a local-resolver issue."
      warn "DNS may be blocked on this network; leaving /etc/resolv.conf unchanged."
      return 1
    fi
  else
    warn "Could not verify via public DNS (nslookup unavailable); applying 1.1.1.1 anyway."
  fi

  # Back up the current resolv.conf (often an OrbStack-managed symlink) then replace it.
  if [ -e /etc/resolv.conf ] && [ ! -e /etc/resolv.conf.devsys.bak ]; then
    $SUDO cp -L /etc/resolv.conf /etc/resolv.conf.devsys.bak 2>/dev/null \
      && ok "Backed up /etc/resolv.conf -> /etc/resolv.conf.devsys.bak"
  fi
  # Write via a temp file + atomic mv so a failed write never leaves resolv.conf missing.
  local _rctmp=/etc/resolv.conf.devsys.tmp
  if printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0\n' | $SUDO tee "$_rctmp" >/dev/null; then
    $SUDO mv "$_rctmp" /etc/resolv.conf
  else
    err "Failed to write new resolv.conf; leaving DNS unchanged."
    $SUDO rm -f "$_rctmp" 2>/dev/null || true
    return 1
  fi

  if _dns_ok_system "$host"; then
    ok "$host resolves now. Retry: devsys backup"
    if have systemctl && confirm "Reapply this public-DNS fix automatically on every boot? (recommended on OrbStack, which resets DNS)"; then
      mkdir -p "$CFG_DIR"; printf 'DEVSYS_DNS_FIX=1\n' > "$CFG_DIR/dns.env"
      _install_dns_boot_unit && ok "Enabled boot DNS reapply (devsys-dns.service)."
    fi
    warn "Note: if not enabled above, your VM host may reset /etc/resolv.conf on reboot — re-run 'devsys fix-dns' then."
    return 0
  fi
  err "Still cannot resolve $host after setting a public resolver."
  return 1
}
cmd_reset() {
  warn "Reset never touches ~/work."
  if confirm "1) Delete local devsys config ($CFG_DIR)?"; then rm -rf "$CFG_DIR" && ok "Removed $CFG_DIR"; fi

  if confirm "2) Log out / remove CLI auth dirs (.claude .codex .gemini .config/gh .fly .config/neonctl)?"; then
    echo "  Will remove: ~/.claude ~/.codex ~/.gemini ~/.config/gh ~/.fly ~/.config/neonctl" >&2
    confirm "  Confirm removal?" && rm -rf "$HOME/.claude" "$HOME/.codex" "$HOME/.gemini" \
      "$HOME/.config/gh" "$HOME/.fly" "$HOME/.config/neonctl" && ok "CLI auths removed"
  fi

  if [ -f "$TIGRIS_ENV" ] && confirm "3) Delete a remote backup bundle from Tigris?"; then
    # shellcheck disable=SC1090 # TIGRIS_ENV is our own generated config, not user input
    . "$TIGRIS_ENV"
    local name; name=$(_sanitize_name "$(ask "  Backup name to delete" "default")")
    local key; key=$(_bundle_key "$name")
    local prevkey; prevkey=$(_bundle_prev_key "$name")
    local typed; typed=$(ask "  Type the bucket name '$TIGRIS_BUCKET' to confirm")
    if [ "$typed" = "$TIGRIS_BUCKET" ]; then
      # VERIFIED against `tigris rm --help` / `tigris objects --help` (@tigrisdata/cli
      # 3.4.3): there is no `tigris objects rm`. The real subcommands are the
      # top-level `tigris rm|remove <t3://path>` and the low-level `tigris objects
      # delete|d <bucket> [key]`. Try the top-level form first, fall back to the
      # low-level one; -y/--yes skips the CLI's own confirmation (we already got
      # ours above). Deletes both the named bundle and its rotated .prev copy.
      local failed=0 rmkey
      for rmkey in "$key" "$prevkey"; do
        tigris rm -y "t3://$TIGRIS_BUCKET/$rmkey" 2>/dev/null \
          || tigris objects delete -y "$TIGRIS_BUCKET" "$rmkey" 2>/dev/null \
          || failed=1
      done
      if [ "$failed" = 0 ]; then
        ok "Remote bundle(s) deleted ($key, $prevkey)"
      else
        warn "Remote delete failed for one or more objects (a missing .prev is normal if no prior backup existed)"
      fi
    else warn "Bucket name mismatch; skipped remote delete"; fi
  fi

  confirm "4) Re-run install now?" && cmd_install
  return 0
}
# ---- tailscale serve ----
# Valid TCP port: digits only, in range 1-65535. Written with case/test (not
# [[ =~ ]]) to match this script's existing conditional style.
_valid_port() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# List listening TCP ports (best-effort process names via `ss -ltnpH`).
# Never aborts the script: every parse step tolerates empty/missing `ss` output.
_list_ports() {
  have ss || { warn "'ss' not found; cannot list listening ports."; return 1; }
  local raw
  raw=$(ss -ltnH 2>/dev/null) || raw=""
  [ -n "$raw" ] || { warn "No listening TCP ports found."; return 1; }

  local ports
  ports=$(printf '%s\n' "$raw" | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)
  [ -n "$ports" ] || { warn "No listening TCP ports found."; return 1; }

  local praw
  praw=$(ss -ltnpH 2>/dev/null) || praw=""

  log "Listening TCP ports:"
  local port proc
  while IFS= read -r port; do
    [ -n "$port" ] || continue
    proc=""
    if [ -n "$praw" ]; then
      # Anchor on ":<port>" at the end of the local-address field so port 300
      # can't spuriously match port 3001.
      proc=$(printf '%s\n' "$praw" | awk -v p=":$port" '$4 ~ (p"$"){print; exit}' \
        | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null) || proc=""
    fi
    if [ -n "$proc" ]; then printf '  %-6s %s\n' "$port" "$proc" >&2
    else printf '  %-6s\n' "$port" >&2; fi
  done <<< "$ports"
  return 0
}

# Serve a single port over Tailscale HTTPS at the same port number (--bg makes
# it persist across reboots/reconnects) and print the resulting URL.
_serve_port() {
  local port="$1"
  _valid_port "$port" || { err "Invalid port: $port (must be 1-65535)"; return 1; }

  if ! $SUDO tailscale serve --bg --https="$port" "127.0.0.1:$port"; then
    warn "If this says HTTPS is disabled, enable MagicDNS + HTTPS certificates in the Tailscale admin console (DNS page)."
    return 1
  fi

  local name
  name=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//')
  if [ -z "${name:-}" ]; then
    name=$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName // empty' 2>/dev/null)
  fi

  tailscale serve status

  if [ -n "${name:-}" ]; then
    ok "Serving 127.0.0.1:$port  ->  https://$name:$port"
  else
    warn "Could not determine node name; see 'tailscale serve status' above for the URL."
  fi
  log "Stop: devsys serve off $port   |   List all: devsys serve status"
  return 0
}

cmd_serve() {
  have tailscale || { err "tailscale not installed."; return 1; }
  have jq || warn "jq not found; URL may be incomplete"

  local sub="${1:-}"
  case "$sub" in
    off)
      shift || true
      local port="${1:-}"
      _valid_port "$port" || { err "Invalid port: ${port:-<none>} (must be 1-65535)"; return 1; }
      if $SUDO tailscale serve --https="$port" off; then
        ok "Stopped serving port $port"
      else
        err "Failed to stop serve for port $port"
        return 1
      fi
      ;;
    status)
      local name
      name=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//')
      [ -n "${name:-}" ] && log "Node: $name"
      tailscale serve status
      ;;
    "")
      _list_ports || return 0
      local answer
      answer=$(ask "Which port to expose over Tailscale?")
      if [ -n "${answer:-}" ] && _valid_port "$answer"; then
        _serve_port "$answer"; return $?
      else
        err "Invalid or empty port."
        return 1
      fi
      ;;
    *)
      _serve_port "$sub"; return $?
      ;;
  esac
  return 0
}

# Placeholder — Task 13 (publish) sets the real gist raw URL at release time.
GIST_RAW_URL="https://gist.githubusercontent.com/sohebcakewalk/dee2808e92831d35fadf30492e4f5711/raw/devsys-vm.sh"
cmd_update() {
  local tmp; tmp="$(mktemp)" || return 1
  # Self-clearing: same RETURN-trap pattern as cmd_backup/cmd_restore above, so
  # $tmp never leaks into a later, out-of-scope trap fire.
  trap 'rm -f "$tmp"; trap - RETURN' RETURN
  curl -fsSL "$GIST_RAW_URL" -o "$tmp" || { err "Download failed."; return 1; }
  bash -n "$tmp" || { err "Downloaded script failed parse check; not installing."; return 1; }
  $SUDO install -m 0755 "$tmp" "$SELF_PATH" && ok "Updated devsys -> $SELF_PATH"
  return 0
}

cmd_help() {
  cat >&2 <<EOF
devsys $DEVSYS_VERSION — dev VM bootstrap & backup

Usage: devsys <command>
  install   Interactive setup wizard (default)
  logins    Show auth status + login command for each CLI
  backup    Encrypt & upload auth/config snapshot to Tigris
  restore   Download & restore snapshot from Tigris, re-clone repos
  status    Tailscale / services / tools / last-backup health
  serve     Expose a local app (port) over Tailscale HTTPS and print its URL
  fix-dns   Diagnose & fix DNS so the Tigris endpoint resolves (public resolver)
  reconfigure  Re-enter Tigris credentials (key/secret/bucket) and re-verify write access
  reset     Wipe devsys config (and optionally auths / remote bundle)
  update    Re-fetch latest script from the gist
  help      This message
EOF
}

main() {
  mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR" 2>/dev/null || true
  local cmd="${1:-install}"; shift || true
  case "$cmd" in
    install) cmd_install "$@";;
    logins)  cmd_logins "$@";;
    backup)  cmd_backup "$@";;
    restore) cmd_restore "$@";;
    status)  cmd_status "$@";;
    serve)   cmd_serve "$@";;
    fix-dns) cmd_fix_dns "$@";;
    reconfigure) cmd_reconfigure "$@";;
    reset)   cmd_reset "$@";;
    update)  cmd_update "$@";;
    help|-h|--help) cmd_help;;
    *) err "Unknown command: $cmd"; cmd_help; exit 1;;
  esac
}

main "$@"