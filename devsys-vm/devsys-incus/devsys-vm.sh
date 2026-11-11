#!/usr/bin/env bash
# devsys-vm (v3) — group-based, version-pinned Ubuntu/Debian dev toolchain.
#
# Publish this file and use:
#   curl -fsSL <raw-url>/devsys-vm.sh | bash
#
# v3 vs v2: Homebrew is GONE.  mise is installed directly, system-wide, as
# root into a shared store (/opt/devsys/mise) — so the whole install runs as
# root with no non-root "brew owner" handoff, and every user (root + each dev)
# runs the pinned tools from shared shims on PATH.  Tools are selected by
# GROUP (see `devsys --list`); every version is pinned for identical VMs.
#
# Designed for the Incus golden-image workflow: install all groups once in a
# base VM, publish it, and clone for every developer.
#
# shellcheck disable=SC1090,SC1091,SC2015,SC2016,SC2086
# (SC2086: the space-separated tool/package lists are split into args on
#  purpose; SC2015/2016/109x as in prior versions.)
set -Eeuo pipefail

# cloud-init's runcmd can run with HOME unset; guard the first expansion.
: "${HOME:=/root}"

DEVSYS_VERSION="3.2.0"
GIST_RAW_URL="${DEVSYS_SCRIPT_URL:-https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/devsys-v3.sh}"
SELF_PATH="/usr/local/bin/devsys"
CFG_DIR="${HOME}/.config/devsys"
WORK_DIR="${DEVSYS_WORK_DIR:-${HOME}/work}"
TIGRIS_ENV="${CFG_DIR}/tigris.env"
CURL_OPTS=(-fsSL --proto '=https' --tlsv1.2 --retry 3)

# ── Shared, root-owned mise store (replaces Homebrew) ────────────────────────
MISE_BIN="/usr/local/bin/mise"
MISE_ROOT="/opt/devsys/mise"          # MISE_DATA_DIR and MISE_CONFIG_DIR
MISE_SELF="v2026.8.4"                 # pinned mise version itself
NODE_PIN="26.5.0"                     # node version npm CLIs run under

# Optional (DEVSYS_SHARED_CLAUDE=1): share ONE Claude Code login across every
# Unix user ON THIS VM — sign in once, root+all dev users use it.  Only Claude's
# own config is shared (auth, agents, settings, history); gh/git stay per-user,
# so per-account GitHub separation is untouched.  Never share across VMs.
SHARED_CLAUDE_DIR="/opt/devsys/claude"
DEVS_GROUP="devs"

# ── Version pins, organised by group (this is what keeps v3 reproducible) ────
MISE_CLI="ripgrep@15.2.0 fd@10.4.2 bat@0.26.1 fzf@0.74.2 eza@0.23.5 jq@1.8.2 glow@2.1.2 lazygit@0.64.0 age@1.3.1"
MISE_EDITORS="micro@2.0.15"
MISE_SHELL="starship@1.26.0 direnv@2.37.1"
MISE_NODE="node@${NODE_PIN} bun@1.3.14 pnpm@11.21.0"
MISE_PYTHON="python@3.12.13"
MISE_CLOUD="gh@2.96.0 flyctl@0.4.78"
NPM_CLOUD="neonctl@3.1.1 @tigrisdata/cli@3.7.0"
NPM_AI="@anthropic-ai/claude-code@2.1.227 @openai/codex@0.147.0 @google/gemini-cli@0.54.4 opencode-ai@1.18.16"
APT_BASE="ca-certificates curl wget file git gnupg lsb-release sudo unzip zip vim less htop ncdu rsync tmux openssh-client iputils-ping dnsutils net-tools locales bash-completion"
APT_BUILD="build-essential pkg-config bubblewrap procps python3-pip python3-venv"
APT_DATA="redis-server postgresql-client"
# z: arrow-key tmux session/window picker from amitpareek/devsys.  Pinned to a
# commit AND a checksum, so the file that runs is exactly the one reviewed.
Z_URL="https://raw.githubusercontent.com/amitpareek/devsys/2e9875036ff24a1c239b515fbea330decb61397e/z.sh"
Z_SHA256="bde7599c7df7fd7937581ec4460a660fe99a2f242296fecebfb312af303cd464"

# Canonical run order (dependencies flow left→right).
GROUP_ORDER=(base build tailscale data mise cli editors shell node python cloud ai)
# Default groups when none are given (ai-yolo-style dangerous groups excluded).
GROUP_DEFAULT="base build tailscale data mise cli editors shell node python cloud ai"

group_desc() { case $1 in
  base)      echo "apt essentials (git, curl, wget, vim, tmux, htop, rsync…) + Mac locale fix";;
  build)     echo "compiler toolchain (build-essential, pkg-config, bubblewrap, python3 pip + venv)";;
  tailscale) echo "tailscale + tailscaled (installed, NOT joined)";;
  data)      echo "redis-server, postgresql-client";;
  mise)      echo "mise version manager, shared store in $MISE_ROOT (required by most)";;
  cli)       echo "pinned CLI kit: ripgrep fd bat fzf eza jq glow lazygit age";;
  editors)   echo "micro (pinned) + nano";;
  shell)     echo "zsh + starship + direnv (pinned); fzf keys, completions, tmux mouse, z picker";;
  node)      echo "node bun pnpm (pinned, via mise)";;
  python)    echo "python 3.12 (pinned, via mise)";;
  cloud)     echo "gh flyctl (mise) + neonctl tigris (npm), all pinned";;
  ai)        echo "claude codex gemini opencode (pinned, via npm)";;
  *)         echo "unknown group";;
esac; }

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
require_root() { is_root || { err "This must run as root (the whole install is root-side in v3)."; return 1; }; }
require_tty() { { : </dev/tty; } 2>/dev/null || { err "This command needs an interactive terminal."; return 1; }; }
ask() { local p=$1 d=${2:-} a; if [[ -n $d ]]; then printf '%s [%s]: ' "$p" "$d" >&2; else printf '%s: ' "$p" >&2; fi; read -r a </dev/tty || a=""; printf '%s' "${a:-$d}"; }
ask_secret() { local a; printf '%s: ' "$1" >&2; read -rs a </dev/tty || a=""; printf '\n' >&2; printf '%s' "$a"; }
confirm() { local a; printf '%s [y/N]: ' "$1" >&2; read -r a </dev/tty || a=""; [[ $a == [yY] ]]; }
backup_once() { [[ -e $1 && ! -e $1.devsys.bak ]] && cp -a "$1" "$1.devsys.bak" && warn "Backed up $1 -> $1.devsys.bak" || true; }
run_step() { local label=$1; shift; log "$label"; "$@" && ok "$label" || { err "Failed: $label"; return 1; }; }

require_apt() { have apt-get || { err "devsys supports Ubuntu/Debian only (apt-get is missing)."; return 1; }; }
apt_update() { as_root apt-get update -y; }
# --force-confdef/confold + </dev/null: dpkg must never stop to ask about a
# config file devsys already wrote (grp_mise creates /etc/zsh/zshenv before the
# zsh package arrives), and must never read the caller's stdin for an answer.
apt_install() {
  require_apt
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" </dev/null
}
os_release_value() { [[ -r /etc/os-release ]] && (. /etc/os-release && eval "printf '%s' \"\${$1:-}\"") || true; }

# ── mise, run as root against the shared store ───────────────────────────────
mise_root() { as_root env MISE_DATA_DIR="$MISE_ROOT" MISE_CONFIG_DIR="$MISE_ROOT" MISE_CACHE_DIR="$MISE_ROOT/cache" MISE_YES=1 "$MISE_BIN" "$@"; }
mise_share() { as_root chmod -R a+rX "$MISE_ROOT" 2>/dev/null || true; }        # keep world-readable
npm_global() { local p; for p in "$@"; do mise_root exec "node@$NODE_PIN" -- npm install -g "$p"; done; mise_root reshim; }

# ── Group installers ─────────────────────────────────────────────────────────
grp_base()      { apt_update; apt_install $APT_BASE; fix_locale; }
# A Mac's ssh client forwards LC_CTYPE=UTF-8, which is not a locale name on
# Linux, so every shell prints "setlocale: LC_CTYPE: cannot change locale
# (UTF-8)".  Tailscale SSH always forwards it, so make the name valid instead:
# compile a locale literally called "UTF-8".  DEVSYS_FIX_LOCALE=0 skips this.
fix_locale() {
  [[ ${DEVSYS_FIX_LOCALE:-1} == 1 ]] || return 0
  [[ -e /usr/lib/locale/UTF-8/LC_CTYPE ]] && return 0
  # localedef exits non-zero on harmless warnings, so judge by the result.
  as_root localedef -i en_US -f UTF-8 /usr/lib/locale/UTF-8 >/dev/null 2>&1 || true
  [[ -e /usr/lib/locale/UTF-8/LC_CTYPE ]] || warn "Could not compile the 'UTF-8' locale."
}
grp_build()     { apt_install $APT_BUILD; }
grp_data()      { apt_install $APT_DATA; as_root systemctl enable --now redis-server 2>/dev/null || warn "Redis installed but not enabled."; }
grp_tailscale() {
  have tailscale && return 0
  local id codename
  id=$(os_release_value ID); codename=$(os_release_value VERSION_CODENAME)
  case "$id" in ubuntu|debian) ;; *) id=ubuntu;; esac
  [[ -n $codename ]] || codename=$(lsb_release -cs 2>/dev/null || printf 'noble')
  curl "${CURL_OPTS[@]}" "https://pkgs.tailscale.com/stable/${id}/${codename}.noarmor.gpg" | as_root tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl "${CURL_OPTS[@]}" "https://pkgs.tailscale.com/stable/${id}/${codename}.tailscale-keyring.list" | as_root tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt_update; apt_install tailscale
  as_root systemctl enable --now tailscaled 2>/dev/null || true
}
grp_mise() {
  install_mise
  # Shared-store env + shims on PATH for EVERY shell, not just login ones:
  #   /etc/profile.d  → login shells (console/ssh login, `bash -l`)
  #   /etc/bash.bashrc→ interactive non-login bash (e.g. `incus exec … bash`)
  #   /etc/zsh/zshenv → zsh in any mode (dev users' shell)
  as_root tee /etc/profile.d/devsys.sh >/dev/null <<EOF
export MISE_DATA_DIR="$MISE_ROOT"
export MISE_CONFIG_DIR="$MISE_ROOT"
export PATH="$MISE_ROOT/shims:\$PATH"
# Keep the fleet on the versions devsys pinned: stop Claude Code (and the other
# npm CLIs) from auto-updating past them.  Drift otherwise re-triggers Claude's
# first-run onboarding wizard on every VM after each silent self-update.
export DISABLE_AUTOUPDATER=1
# Locale: default to C.UTF-8 (built into glibc), and normalise the
# LC_CTYPE=UTF-8 that macOS ssh clients forward.
[ -z "\${LANG:-}" ] && export LANG=C.UTF-8
[ "\${LC_CTYPE:-}" = "UTF-8" ] && export LC_CTYPE=C.UTF-8
# Default editor: micro, then nano, then vim.  Never overrides one you set.
if [ -z "\${EDITOR:-}" ]; then
  for _e in micro nano vim; do
    command -v "\$_e" >/dev/null 2>&1 && { export EDITOR="\$_e"; break; }
  done
  unset _e
fi
[ -n "\${EDITOR:-}" ] && [ -z "\${VISUAL:-}" ] && export VISUAL="\$EDITOR"
:  # keep last: sourcing this file must not return non-zero
EOF
  as_root chmod 0644 /etc/profile.d/devsys.sh
  local src='[ -f /etc/profile.d/devsys.sh ] && . /etc/profile.d/devsys.sh'
  as_root grep -qxF "$src" /etc/bash.bashrc 2>/dev/null || printf '%s\n' "$src" | as_root tee -a /etc/bash.bashrc >/dev/null
  as_root install -d -m 0755 /etc/zsh
  as_root grep -qxF "$src" /etc/zsh/zshenv 2>/dev/null || printf '%s\n' "$src" | as_root tee -a /etc/zsh/zshenv >/dev/null
}
install_mise() {
  as_root install -d -m 0755 "$(dirname "$MISE_ROOT")" "$MISE_ROOT" "$MISE_ROOT/cache"
  if [[ ! -x $MISE_BIN ]]; then
    log "Installing mise ${MISE_SELF} to $MISE_BIN"
    curl "${CURL_OPTS[@]}" https://mise.run | as_root env MISE_INSTALL_PATH="$MISE_BIN" MISE_VERSION="$MISE_SELF" sh
  fi
  [[ -x $MISE_BIN ]] || { err "mise was not installed."; return 1; }
}
grp_cli()     { mise_use $MISE_CLI; }
grp_editors() { apt_install nano; mise_use $MISE_EDITORS; }
grp_shell()   { apt_install zsh; mise_use $MISE_SHELL; setup_shell_rc; setup_tmux; }
grp_node()    { mise_use $MISE_NODE; }
grp_python()  { mise_use $MISE_PYTHON; }
grp_cloud()   { mise_use $MISE_CLOUD; ensure_node; npm_global $NPM_CLOUD; }
grp_ai()      { ensure_node; npm_global $NPM_AI; setup_ai_autoupdate; }

mise_use() { mise_root use --global "$@"; mise_root reshim; mise_share; }

# Interactive shell setup for EVERY user, zsh and bash alike, kept in
# /etc/devsys and loaded from the system rc files — so root, each dev, and any
# account added later get the same prompt, aliases, history and key bindings
# without touching their own rc file.  The files are regenerated on every run.
setup_shell_rc() {
  as_root install -d -m 0755 /etc/devsys
  as_root tee /etc/devsys/aliases.sh >/dev/null <<'EOF'
# Written by devsys — shared by zsh and bash.
command -v eza     >/dev/null 2>&1 && alias ls='eza'
command -v eza     >/dev/null 2>&1 && alias ll='eza -la --git'
command -v eza     >/dev/null 2>&1 && alias tree='eza --tree'
command -v bat     >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v lazygit >/dev/null 2>&1 && alias lg='lazygit'
:
EOF
  as_root tee /etc/devsys/rc.zsh >/dev/null <<'EOF'
# Written by devsys — interactive zsh setup for every user.  Regenerated by
# `devsys install shell`; put your own settings in ~/.zshrc.
HISTSIZE=10000
SAVEHIST=10000
[ -n "$HISTFILE" ] || HISTFILE="$HOME/.zsh_history"
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE
# Ubuntu's /etc/zsh/zshrc has already run compinit; Debian's has not.
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit -i; }
command -v direnv   >/dev/null 2>&1 && eval "$(direnv hook zsh)"
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
# ctrl-r history search, ctrl-t file picker, alt-c cd.
command -v fzf      >/dev/null 2>&1 && eval "$(fzf --zsh 2>/dev/null)"
[ -f /etc/devsys/aliases.sh ] && . /etc/devsys/aliases.sh
# Land in ~/work on a fresh login — only from $HOME, so a shell started
# somewhere on purpose stays there.
[ -d "$HOME/work" ] && [ "$PWD" = "$HOME" ] && cd "$HOME/work"
:
EOF
  as_root tee /etc/devsys/rc.bash >/dev/null <<'EOF'
# Written by devsys — interactive bash setup for every user.  Regenerated by
# `devsys install shell`; put your own settings in ~/.bashrc.
HISTSIZE=10000
HISTFILESIZE=10000
HISTCONTROL=ignoreboth
shopt -s histappend checkwinsize 2>/dev/null || true
if ! shopt -oq posix; then
  [ -r /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
fi
command -v direnv   >/dev/null 2>&1 && eval "$(direnv hook bash)"
command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"
command -v fzf      >/dev/null 2>&1 && eval "$(fzf --bash 2>/dev/null)"
[ -f /etc/devsys/aliases.sh ] && . /etc/devsys/aliases.sh
[ -d "$HOME/work" ] && [ "$PWD" = "$HOME" ] && cd "$HOME/work"
:
EOF
  as_root chmod 0644 /etc/devsys/aliases.sh /etc/devsys/rc.zsh /etc/devsys/rc.bash
  local zsrc='[ -f /etc/devsys/rc.zsh ] && . /etc/devsys/rc.zsh' bsrc='[ -f /etc/devsys/rc.bash ] && . /etc/devsys/rc.bash'
  as_root grep -qxF "$zsrc" /etc/zsh/zshrc 2>/dev/null || printf '%s\n' "$zsrc" | as_root tee -a /etc/zsh/zshrc >/dev/null
  as_root grep -qxF "$bsrc" /etc/bash.bashrc 2>/dev/null || printf '%s\n' "$bsrc" | as_root tee -a /etc/bash.bashrc >/dev/null
}

setup_tmux() {
  # Appended, so an existing /etc/tmux.conf survives.
  as_root grep -qsE '^set -g mouse' /etc/tmux.conf || printf 'set -g mouse on\n' | as_root tee -a /etc/tmux.conf >/dev/null
  local tmp; tmp=$(mktemp)
  if curl "${CURL_OPTS[@]}" "$Z_URL" -o "$tmp" && printf '%s  %s\n' "$Z_SHA256" "$tmp" | sha256sum -c --status; then
    as_root install -m 0755 "$tmp" /usr/local/bin/z
  else
    warn "Could not fetch or verify the z tmux picker; skipping it."
  fi
  rm -f "$tmp"
}

# Completion scripts for whichever CLIs are installed, generated once
# system-wide so nobody has to wire them into an rc file.  Runs after all
# groups, because the tools come from groups later than 'shell'.
setup_completions() {
  have zsh || return 0
  local zdir=/usr/local/share/zsh/site-functions bdir=/etc/bash_completion.d spec bin tmpl sh out
  as_root install -d -m 0755 "$zdir" "$bdir"
  for spec in 'gh|completion -s SHELL' 'flyctl|completion SHELL' 'starship|completions SHELL' 'tailscale|completion SHELL'; do
    bin=${spec%%|*}; tmpl=${spec#*|}
    for sh in zsh bash; do
      out=$(env PATH="$MISE_ROOT/shims:$PATH" MISE_DATA_DIR="$MISE_ROOT" MISE_CONFIG_DIR="$MISE_ROOT" \
        "$bin" ${tmpl//SHELL/$sh} 2>/dev/null </dev/null) || continue
      (( ${#out} > 100 )) || continue          # a real script, not an error line
      if [[ $sh == zsh ]]; then printf '%s\n' "$out" | as_root tee "$zdir/_$bin" >/dev/null
      else printf '%s\n' "$out" | as_root tee "$bdir/$bin" >/dev/null; fi
    done
  done
  return 0
}
ensure_node() { mise_root ls node 2>/dev/null | grep -q "$NODE_PIN" || mise_use $MISE_NODE; }

# Reinstall the AI CLIs at @latest (the versions in NPM_AI are only the baseline
# a fresh install/golden image ships with; a weekly timer keeps the shared,
# root-owned install current for every user without touching the npm pins).
cmd_update_ai() {
  local pkgs=() p
  for p in $NPM_AI; do pkgs+=("${p%@*}@latest"); done
  log "Updating AI CLIs to latest: ${pkgs[*]}"
  npm_global "${pkgs[@]}"; mise_share
  ok "AI CLIs updated."
}

# Bake a weekly systemd timer that runs the update above as root.  We drive the
# update ourselves rather than Claude's built-in auto-updater, which can't write
# the root-owned shared store from a dev user's session (DISABLE_AUTOUPDATER=1
# is set in the toolchain env file to keep the two from fighting).
setup_ai_autoupdate() {
  as_root tee /etc/systemd/system/devsys-ai-update.service >/dev/null <<EOF
[Unit]
Description=Update devsys AI CLIs (claude, codex, gemini, opencode) to latest
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF_PATH update-ai
EOF
  as_root tee /etc/systemd/system/devsys-ai-update.timer >/dev/null <<'EOF'
[Unit]
Description=Weekly update of the devsys AI CLIs
[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  as_root systemctl daemon-reload 2>/dev/null || true
  as_root systemctl enable --now devsys-ai-update.timer 2>/dev/null || true
}

# ── Group selection ──────────────────────────────────────────────────────────
valid_group() { local g; for g in "${GROUP_ORDER[@]}"; do [[ $g == "$1" ]] && return 0; done; return 1; }
expand_groups() {
  # Echo the requested groups in canonical order, auto-adding dependencies:
  # anything mise-backed needs 'mise'; npm groups (cloud, ai) need 'node'.
  local -A want=(); local g
  for g in "$@"; do valid_group "$g" || { err "Unknown group: $g (see: devsys --list)"; return 1; }; want[$g]=1; done
  for g in cli editors shell node python cloud ai; do [[ ${want[$g]:-} ]] && want[mise]=1; done
  for g in cloud ai; do [[ ${want[$g]:-} ]] && { want[node]=1; want[mise]=1; }; done
  local out=()
  for g in "${GROUP_ORDER[@]}"; do [[ ${want[$g]:-} ]] && out+=("$g"); done
  printf '%s\n' "${out[@]}"
}
install_groups() {
  local groups; groups=$(expand_groups "$@") || return 1
  local g; while IFS= read -r g; do
    [[ -n $g ]] || continue
    # </dev/null: the loop reads the group list on stdin, so a group command
    # that reads stdin would swallow the remaining groups and skip them silently.
    run_step "group: $g" "grp_$g" </dev/null
  done <<<"$groups"
  mise_share
  run_step "shell completions" setup_completions
}
cmd_list() {
  printf 'devsys %s — install groups (pass names to `devsys install`):\n' "$DEVSYS_VERSION"
  local g; for g in "${GROUP_ORDER[@]}"; do printf '  %-10s %s\n' "$g" "$(group_desc "$g")"; done
  printf '\nDefault: %s\n' "$GROUP_DEFAULT"
  printf 'Example: devsys install node python cloud ai\n'
}

# ── Dev user + per-user config (root writes it; no brew handoff needed) ───────
valid_username() { [[ ${1:-} =~ ^[a-z_][a-z0-9_-]*$ ]]; }
select_dev_user() {
  local user=${DEVSYS_USER:-}
  if [[ -z $user ]]; then
    [[ ${DEVSYS_UNATTENDED:-} == 1 ]] && { err "DEVSYS_UNATTENDED=1 requires DEVSYS_USER."; return 1; }
    user=$(ask "Development username" "${SUDO_USER:-dev}")
  fi
  valid_username "$user" || { err "Invalid Linux username: $user"; return 1; }
  if ! id "$user" >/dev/null 2>&1; then
    log "Creating user '$user' (password disabled; Tailscale SSH is the front door)."
    as_root adduser --disabled-password --gecos "" "$user" >&2
  fi
  as_root usermod -aG sudo "$user"
  # The account is --disabled-password (Tailscale SSH / installed keys are the
  # front door), so password-based sudo can never authenticate.  Grant
  # passwordless sudo to match — otherwise the user's own `sudo`, and every
  # `devsys` subcommand that needs root (mise/npm/serve/fix-dns), fails.
  local sudoers="/etc/sudoers.d/90-devsys-$user"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" | as_root tee "$sudoers" >/dev/null
  as_root chmod 0440 "$sudoers"
  as_root visudo -cf "$sudoers" >/dev/null 2>&1 || { warn "Invalid sudoers drop-in for $user; removing it."; as_root rm -f "$sudoers"; }
  printf '%s' "$user"
}
configure_user() {
  local user=$1 home; home=$(getent passwd "$user" | cut -d: -f6); [[ -n $home ]] || return 1
  # NB: GNU `install -d` gives *intermediate* parents (like ~/.config) the
  # DEFAULT (root) owner — only named dirs get -o/-g.  So name ~/.config
  # explicitly, and chown it in case an older run already left it root-owned
  # (otherwise the user's first `mkdir ~/.config/<x>` — e.g. gh — fails).
  as_root install -d -o "$user" -g "$user" \
    "$home/.config" "$home/.config/devsys" \
    "$home/work" "$home/.claude" "$home/.codex" "$home/.gemini"
  as_root chown "$user:$user" "$home/.config"
  [[ -f $home/.codex/config.toml ]] || printf '%s\n' '# Devsys leaves Codex approval/sandbox at secure defaults.' | as_root tee "$home/.codex/config.toml" >/dev/null
  local tmp; tmp=$(mktemp)
  [[ -f $home/.zshrc ]] && as_root cat "$home/.zshrc" > "$tmp" 2>/dev/null || true
  # Strip any prior managed block, then append a fresh one.
  local clean; clean=$(mktemp)
  awk '/^# >>> devsys >>>$/ {skip=1; next} /^# <<< devsys <<<$/{skip=0; next} !skip {print}' "$tmp" > "$clean"
  # The file must exist either way: with no ~/.zshrc, zsh greets a new user
  # with its first-run configuration wizard.
  if [[ -f /etc/devsys/rc.zsh ]]; then
    cat >> "$clean" <<'EOF'
# >>> devsys >>>
# Prompt, aliases, history, completions and tool paths are set system-wide in
# /etc/devsys/rc.zsh (loaded by /etc/zsh/zshrc).  Add your own settings below.
# <<< devsys <<<
EOF
  else
    # Image built by devsys < 3.2.0 (no system-wide rc): keep the per-user block.
    cat >> "$clean" <<EOF
# >>> devsys >>>
export MISE_DATA_DIR="$MISE_ROOT"
export MISE_CONFIG_DIR="$MISE_ROOT"
export PATH="$MISE_ROOT/shims:\$PATH"
command -v direnv >/dev/null && eval "\$(direnv hook zsh)"
command -v starship >/dev/null && eval "\$(starship init zsh)"
alias ls='eza'
alias ll='eza -la --git'
alias tree='eza --tree'
alias cat='bat --paging=never'
alias lg='lazygit'
# <<< devsys <<<
EOF
  fi
  as_root install -o "$user" -g "$user" -m 0644 "$clean" "$home/.zshrc"
  rm -f "$tmp" "$clean"
  # If shared Claude is set up (the 'devs' group exists), enrol this user so
  # they read the one shared login automatically.
  getent group "$DEVS_GROUP" >/dev/null 2>&1 && as_root usermod -aG "$DEVS_GROUP" "$user" || true
  have zsh && as_root chsh -s "$(command -v zsh)" "$user" || warn "Could not set zsh for $user."
}

# Share one Claude Code login across all Unix users on this VM.  Creates the
# 'devs' group + a group-owned CLAUDE_CONFIG_DIR and points every shell at it;
# configure_user() enrols each user into 'devs'.  Sign in once, all users share.
setup_shared_claude() {
  as_root groupadd -f "$DEVS_GROUP"
  as_root install -d -m 2770 -g "$DEVS_GROUP" "$SHARED_CLAUDE_DIR"
  have setfacl && as_root setfacl -d -m "g:$DEVS_GROUP:rwx" "$SHARED_CLAUDE_DIR" 2>/dev/null || true
  as_root tee /etc/profile.d/claude-shared.sh >/dev/null <<EOF
export CLAUDE_CONFIG_DIR="$SHARED_CLAUDE_DIR"
umask 002
EOF
  as_root chmod 0644 /etc/profile.d/claude-shared.sh
  local src='[ -f /etc/profile.d/claude-shared.sh ] && . /etc/profile.d/claude-shared.sh'
  as_root grep -qxF "$src" /etc/bash.bashrc 2>/dev/null || printf '%s\n' "$src" | as_root tee -a /etc/bash.bashrc >/dev/null
  as_root install -d -m 0755 /etc/zsh
  as_root grep -qxF "$src" /etc/zsh/zshenv 2>/dev/null || printf '%s\n' "$src" | as_root tee -a /etc/zsh/zshenv >/dev/null
  # Claude writes its credential/config files mode 0600 (owner-only) on every
  # token refresh and when a user installs a plugin or edits settings, which
  # re-locks the other users out of the shared dir.  A oneshot re-grants group
  # access; a .path unit fires it the instant the dir changes (so a refreshed
  # token or a new plugin is visible to the others immediately), and a .timer
  # backstops anything the path watch misses (e.g. writes in subdirectories).
  as_root tee /etc/systemd/system/devsys-claude-share.service >/dev/null <<EOF
[Unit]
Description=Keep shared Claude config readable by the $DEVS_GROUP group
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'chgrp -R $DEVS_GROUP $SHARED_CLAUDE_DIR && chmod -R g+rwX $SHARED_CLAUDE_DIR'
EOF
  as_root tee /etc/systemd/system/devsys-claude-share.path >/dev/null <<EOF
[Unit]
Description=Fix shared Claude config perms the moment the dir changes
[Path]
PathModified=$SHARED_CLAUDE_DIR
Unit=devsys-claude-share.service
[Install]
WantedBy=paths.target
EOF
  as_root tee /etc/systemd/system/devsys-claude-share.timer >/dev/null <<'EOF'
[Unit]
Description=Periodically fix shared Claude config perms (backstop)
[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
  as_root systemctl daemon-reload 2>/dev/null || true
  as_root systemctl enable --now devsys-claude-share.timer 2>/dev/null || true
  as_root systemctl enable --now devsys-claude-share.path 2>/dev/null || true
}

# ── Tailscale connect (env-driven, unattended-safe) ──────────────────────────
setup_tailscale() {
  have tailscale || { err "Tailscale is not installed (select the 'tailscale' group)."; return 1; }
  if tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then ok "Tailscale already connected."; return 0; fi
  local hostname=${DEVSYS_TS_HOSTNAME:-} key=${DEVSYS_TS_AUTHKEY:-} tags=${DEVSYS_TS_TAGS:-} extra=()
  [[ -n $tags ]] && extra+=(--advertise-tags="$tags")
  if [[ -n $key ]]; then
    [[ -n $hostname ]] || hostname=$(hostname -s)
    as_root tailscale up --authkey="$key" --hostname="$hostname" --ssh --accept-dns=false --accept-routes=true "${extra[@]}"; return
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
cmd_ts_login() {
  have tailscale || { err "Tailscale is not installed."; return 1; }
  if as_root tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then ok "Tailscale already connected."; return 0; fi
  local hostname=${DEVSYS_TS_HOSTNAME:-$(hostname -s)} url="" tries=0
  as_root tailscale up --hostname="$hostname" --ssh --accept-dns=false --accept-routes=true >/dev/null 2>&1 & disown
  while (( ++tries <= 30 )); do
    url=$(as_root tailscale status --json 2>/dev/null | sed -n 's/.*"AuthURL": *"\([^"]*\)".*/\1/p' | head -1)
    [[ -n $url ]] && break; sleep 1
  done
  [[ -n $url ]] || { err "Could not obtain a login URL from tailscaled."; return 1; }
  log "Send this link to the developer (must already be a tailnet member):"
  printf '%s\n' "$url"
}

# ── Install orchestration ────────────────────────────────────────────────────
cmd_install() {
  require_root
  # Groups: args > DEVSYS_GROUPS env > default.  'none' skips the toolchain
  # entirely (fast path for cloning from a golden image).
  local groups=("$@")
  [[ ${#groups[@]} -eq 0 ]] && read -r -a groups <<<"${DEVSYS_GROUPS:-$GROUP_DEFAULT}"
  if [[ ${groups[0]:-} != none ]]; then
    install_groups "${groups[@]}"
    run_step "devsys command" cmd_update || warn "Rerun 'devsys update' later."
  fi
  # Shared-Claude setup (before the user block, so 'devs' exists when the user
  # is enrolled).  Runs even with 'install none' so it can retrofit a live VM.
  [[ ${DEVSYS_SHARED_CLAUDE:-} == 1 ]] && run_step "Shared Claude login" setup_shared_claude || true
  # Per-user + Tailscale (skipped only when no user is requested/derivable).
  if [[ -n ${DEVSYS_USER:-} || ${DEVSYS_UNATTENDED:-} != 1 ]]; then
    local user; user=$(select_dev_user)
    run_step "User config ($user)" configure_user "$user"
  fi
  if [[ -n ${DEVSYS_TS_AUTHKEY:-} ]]; then
    run_step "Tailscale connect" setup_tailscale
  elif [[ ${DEVSYS_UNATTENDED:-} != 1 ]]; then
    confirm "Connect this VM to Tailscale now?" && setup_tailscale || true
  fi
  ok "Done."
}

# ── devsys command wrapper (management, run against the shared store) ─────────
cmd_mise() { mise_root "$@"; }
cmd_npm()  { mise_root exec "node@$NODE_PIN" -- npm "$@"; [[ ${1:-} == install ]] && mise_root reshim && mise_share || true; }

login_specs() { cat <<'EOF'
claude|test -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"|claude
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

dns_ok() { getent hosts "${1:-t3.storage.dev}" >/dev/null 2>&1; }
cmd_fix_dns() {
  local host=${1:-t3.storage.dev}; dns_ok "$host" && { ok "$host resolves already."; return 0; }
  confirm "Replace /etc/resolv.conf with Cloudflare and Google DNS?" || return 1
  [[ -e /etc/resolv.conf && ! -e /etc/resolv.conf.devsys.bak ]] && sudo cp -L /etc/resolv.conf /etc/resolv.conf.devsys.bak || true
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions edns0\n' | sudo tee /etc/resolv.conf >/dev/null
  dns_ok "$host" && ok "$host resolves now." || { err "Still unresolved."; return 1; }
}

tigris_load() { [[ -f $TIGRIS_ENV ]] && . "$TIGRIS_ENV" || return 1; }
tigris_configure() {
  have tigris || { err "tigris is not installed; install the 'cloud' group."; return 1; }
  local ak sk bucket; ak=$(ask "Tigris Access Key ID" "${TIGRIS_ACCESS_KEY_ID:-}"); sk=$(ask_secret "Tigris Secret Access Key"); bucket=$(ask "Tigris bucket" "${TIGRIS_BUCKET:-}")
  [[ -n $ak && -n $sk && -n $bucket ]] || { err "All Tigris values are required."; return 1; }
  mkdir -p "$CFG_DIR"
  { printf 'TIGRIS_ACCESS_KEY_ID=%q\n' "$ak"; printf 'TIGRIS_SECRET_ACCESS_KEY=%q\n' "$sk"; printf 'TIGRIS_BUCKET=%q\n' "$bucket"; printf 'AWS_ENDPOINT_URL_S3=%q\n' "https://t3.storage.dev"; } > "$TIGRIS_ENV"
  chmod 600 "$TIGRIS_ENV"
  tigris login credentials --access-key "$ak" --access-secret "$sk"
  tigris buckets create "$bucket" 2>/dev/null || true
  ok "Tigris configured for $bucket."
}
backup_paths=(.claude .codex .gemini .config/gh .fly .config/neonctl .gitconfig .ssh/id_* .ssh/config .zshrc .zprofile .config/devsys)
collect_repos() {
  local output=$1 repo; : > "$output"; [[ -d $WORK_DIR ]] || return 0
  while IFS= read -r repo; do git -C "$(dirname "$repo")" remote get-url origin 2>/dev/null || true; done \
    < <(find "$WORK_DIR" -maxdepth 4 -type d -name .git 2>/dev/null) | sed '/^$/d' | sort -u > "$output"
}
cmd_backup() {
  tigris_load || { warn "Tigris is not configured."; tigris_configure || return 1; tigris_load || return 1; }
  local name pass pass2 temp stage entry expanded; name=$(ask "Backup name" "default"); name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9._-'); [[ -n $name ]] || name=default
  pass=$(ask_secret "Encryption passphrase"); pass2=$(ask_secret "Confirm passphrase"); [[ -n $pass && $pass == "$pass2" ]] || { err "Passphrase empty or mismatched."; return 1; }
  temp=$(mktemp -d); trap 'rm -rf "$temp"' RETURN; stage="$temp/stage"; mkdir -p "$stage"
  for entry in "${backup_paths[@]}"; do for expanded in "$HOME"/$entry; do [[ -e $expanded ]] || continue; mkdir -p "$stage/$(dirname "${expanded#"$HOME"/}")"; cp -a "$expanded" "$stage/${expanded#"$HOME"/}"; done; done
  mkdir -p "$stage/.config/devsys"; collect_repos "$stage/.config/devsys/repos.txt"
  local work_rel=${WORK_DIR#"$HOME"/}
  if [[ -d $WORK_DIR && $work_rel != "$WORK_DIR" ]]; then tar --exclude='node_modules' -czf "$temp/bundle.tar.gz" -C "$stage" . -C "$HOME" "$work_rel"; else tar --exclude='node_modules' -czf "$temp/bundle.tar.gz" -C "$stage" .; fi
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
  confirm "Restore config files into $HOME (existing files overwritten)?" || return 0
  (cd "$temp/extract" && tar -cf - .) | (cd "$HOME" && tar -xpf -)
  chmod 700 "$HOME/.ssh" 2>/dev/null || true; chmod 600 "$HOME"/.ssh/id_* 2>/dev/null || true
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
  local tool; for tool in mise node bun python3 npm gh flyctl tigris claude codex gemini lazygit rg; do
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
  as_root install -m 0755 "$tmp" "$SELF_PATH"; ok "Updated $SELF_PATH"
}
cmd_help() { cat <<EOF
devsys $DEVSYS_VERSION — group-based, version-pinned dev toolchain (mise, no brew)
Usage: devsys <command> [args]
  install [groups…]  Root: install groups (default: all) + dev user + Tailscale.
                     'devsys install none' skips tools (fast clone: user + TS only).
                     DEVSYS_SHARED_CLAUDE=1 shares one Claude login across all
                     this VM's users (gh/git stay per-user).
  --list             Show install groups and what each pins.
  mise …/npm …       Manage the shared toolchain (e.g. devsys mise ls · npm install -g X).
  status/logins      Tool versions, service state, CLI login state.
  ts-login           Print a Tailscale login link for a developer.
  backup/restore     Encrypted Tigris configuration backup and restore.
  update-ai          Reinstall the AI CLIs at @latest (a weekly timer runs this).
  reconfigure/reset/serve/fix-dns/update/help
EOF
}
main() {
  local command=${1:-install}; shift || true
  case "$command" in
    install) cmd_install "$@";; --list|list) cmd_list;;
    mise) cmd_mise "$@";; npm) cmd_npm "$@";;
    ts-login) cmd_ts_login;; logins) cmd_logins;;
    backup) cmd_backup;; restore) cmd_restore;; reconfigure) tigris_configure;; reset) cmd_reset;;
    status) cmd_status;; serve) cmd_serve "$@";; fix-dns) cmd_fix_dns "$@";; update) cmd_update;;
    update-ai) cmd_update_ai;;
    help|-h|--help) cmd_help;;
    *) err "Unknown command: $command"; cmd_help; return 1;;
  esac
}
main "$@"
