# DevSys VM — Incus golden image + grouped toolchain

This folder targets a **bare-metal Ubuntu server running Incus**. For a Mac with OrbStack, use `../devsys-orbstack` — same installer, different host scripts. Two design points, both changed from the earlier Homebrew-based version:

1. **No Homebrew.** `mise` is installed directly, **system-wide, as root**, into a shared store (`/opt/devsys/mise`). The whole install runs as root — no non-root "brew owner" account, no handoff. Every user (root + each dev) runs the pinned tools from shared shims on `PATH`. This resolves the "brew can't run as root" constraint by not using brew.
2. **Group-based, still version-pinned.** Tools are selected by **group** (`devsys --list`); every version is pinned (`MISE_*` / `NPM_*` in the script) so all VMs are identical. Structure borrowed from Amit's installer, reproducibility kept from the earlier version.

The intended workflow is a **golden image**: install the toolchain once into a base VM, publish it, then every dev VM is a ~5-second Incus clone instead of a 10-minute re-install — which also spares the shared uplink.

## Files

| File | Runs on | Purpose |
| --- | --- | --- |
| `devsys-vm.sh` | inside the guest | grouped, pinned, brew-free installer + the `devsys` command |
| `build-base.sh` | Incus host | generalize + publish the base VM as image `devsys-base` |
| `newvm.sh` | Incus host | clone a dev VM from the image, mint a tagged Tailscale key |
| `template.yaml` | (fetched by newvm) | light per-clone cloud-init (hostname, user, Tailscale join) |
| `devsys-incus-runbook.pdf` | — | the step-by-step runbook |

In the gist, `devsys-vm.sh`, `newvm.sh` and `template.yaml` are published as `devsys-v3.sh`, `newvm-v3.sh` and `template-v3.yaml`. The scripts download them by those names, so keep the gist names as they are. (No `Brewfile` — Homebrew is gone.)

## Install groups

```
base       apt essentials (git, curl, wget, vim, tmux, htop, rsync…) + Mac locale fix
build      build-essential, pkg-config, bubblewrap, python3 pip + venv
tailscale  tailscale + tailscaled (installed, NOT joined)
data       redis-server, postgresql-client
mise       mise, shared store /opt/devsys/mise (required by most)
cli        ripgrep fd bat fzf eza jq glow lazygit age   (pinned)
editors    micro + nano                                  (micro pinned)
shell      zsh + starship + direnv (pinned); fzf keys, completions, tmux mouse, z picker
node       node bun pnpm                                  (pinned, mise)
python     python 3.12                                    (pinned, mise)
cloud      gh flyctl (mise) + neonctl tigris (npm)        (pinned)
ai         claude codex gemini opencode (npm)            (pinned)
```

Dependencies auto-resolve: any mise-backed group pulls in `mise`; the npm groups (`cloud`, `ai`) pull in `node`. `devsys install none` installs no tools (used by clones — user + Tailscale only).

Dev users are created **passwordless** (`--disabled-password` — Tailscale SSH / installed keys are the front door) and given **passwordless sudo** (`/etc/sudoers.d/90-devsys-<user>`), since password-based sudo can't authenticate a passwordless account. Each dev therefore has full root on **their own** VM. If you'd rather admin be root-only, remove that drop-in and don't add dev users to `sudo`.

## One-time: build the golden image

1. **Create a base VM** in the Incus Web UI (or CLI): image **`ubuntu/24.04/cloud`**, type **Virtual machine**, name `devsys-base`, ~2 vCPU / 4 GiB / 40 GiB disk.
2. **Open its Terminal tab** (root shell via the agent) and install the full toolchain, unattended, with **no dev user and no Tailscale login**:
   ```bash
   curl -fsSL https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/devsys-v3.sh | DEVSYS_UNATTENDED=1 bash
   ```
   (Omitting `DEVSYS_USER` and `DEVSYS_TS_AUTHKEY` means it installs tools only — exactly what the base should contain.) Then run `devsys status` and check that no tool is listed as missing.
3. **Publish** it as the golden image, from the Incus host:
   ```bash
   ./build-base.sh devsys-base devsys-base
   ```
   This generalizes the VM (clears machine-id, SSH host keys, Tailscale state, cloud-init) — **mandatory**, or clones collide — then publishes image `devsys-base`.

To bump tool versions later: edit the `MISE_*`/`NPM_*` pins, republish the gist, `incus start devsys-base`, re-run the install, then `./build-base.sh` again.

### Installer 3.2.0 — republish the gist before the next base build

3.2.0 adds a set of conveniences taken from [amitpareek/devsys](https://github.com/amitpareek/devsys):

- **Packages:** `wget`, `vim`, `less`, `locales`, `bash-completion` (base) and system `python3-pip` + `python3-venv` (build).
- **Mac locale fix:** a Mac's SSH client forwards `LC_CTYPE=UTF-8`, which is not a valid locale on Linux and makes `locale`, perl and bash print warnings. The base group compiles a locale named `UTF-8` so the value is valid. `DEVSYS_FIX_LOCALE=0` skips it.
- **Shell setup for every user, zsh and bash:** history settings, fzf key bindings (Ctrl-R, Ctrl-T), starship, direnv and the aliases now live in `/etc/devsys/rc.zsh` and `/etc/devsys/rc.bash`, so root and any account added later get them too. A login that starts in `$HOME` lands in `~/work`. In bash, Ubuntu's default `~/.bashrc` runs afterwards and still overrides the `ls`/`ll` aliases and the history size; zsh, the dev users' shell, is unaffected.
- **Completions** for `gh`, `flyctl`, `starship` and `tailscale`, generated system-wide.
- **`$EDITOR`** defaults to micro, then nano, then vim, unless you set one.
- **tmux:** mouse mode on, and `z`, an arrow-key session/window picker. `z` is downloaded from that repository, pinned to one commit and a SHA-256 checksum.

Left out on purpose: `openssh-server` (Tailscale SSH is the front door), and the optional `dotnet`, `docker`, `notes`, `ai-yolo` groups, `devsys-auth` and Taildrive.

It also carries the **3.1.7 fix**, which matters more:

With 3.1.6, a default install could **silently skip the `node`, `python`, `cloud` and `ai` groups and still print "Done"**. The `mise` group writes `/etc/zsh/zshenv` before the `shell` group installs the zsh package, so dpkg stops to ask which version of that file to keep, and its prompt reads the rest of the group list from stdin as the answer.

3.1.7 fixed that (and `devsys status` reporting ripgrep as missing), and `devsys-vm.sh` in this folder is 3.2.0. The gist still serves 3.1.6 as `devsys-v3.sh`, and step 2 above downloads from the gist — so publish this folder's `devsys-vm.sh` there first. The skip was reproduced on OrbStack, not on Incus, but the code path is the same.

## One-time: Tailscale + host setup

- **OAuth client**: Tailscale → Settings → OAuth clients → scope **Auth Keys: Write**, tag `tag:devsys`. Store it on the host in a mode-600 file:
  ```bash
  mkdir -p ~/.config/devsys && chmod 700 ~/.config/devsys
  cat > ~/.config/devsys/ts-oauth.env <<'EOF'
  DEVSYS_TS_CLIENT_ID=tskey-client-xxxx
  DEVSYS_TS_CLIENT_SECRET=tskey-client-secret-xxxx
  EOF
  chmod 600 ~/.config/devsys/ts-oauth.env
  ```
- **tagOwners** (Access controls): `"tag:devsys": ["autogroup:admin", "tag:devsys"]` (self-ownership is required for multi-tag keys) plus `"tag:<dev>": ["tag:devsys"]` per developer.
- **Tailscale SSH** rules: `autogroup:member → autogroup:self`; `autogroup:admin → tag:devsys` (root); per dev `"<dev>@…" → tag:<dev>` (root, `<dev>`). Never use `tag:devsys` as a **source**.
- Host tools: `jq` and Incus (`incus admin init` done).

## Per developer: clone a VM

```bash
./newvm.sh amitvm amit
```

Mints a single-use key tagged `tag:devsys` + `tag:amit`, launches an Incus VM from `devsys-base`, and the light cloud-init creates the `amit` user and joins Tailscale — seconds, since the toolchain is baked in. Reach it as `ssh amit@amitvm` over the tailnet. Adding another dev's VM is the same command with their name — no console change for an existing dev tag.

`newvm.sh` waits for the clone's first boot to finish, then removes the cloud-init user-data (which holds the auth key) from the instance config. The OAuth secret and the auth key are passed to `curl` and `incus` on stdin, so they never appear in the host's process list.

Developer-login mode (dev owns the node, no admin key): `./newvm.sh amitvm amit --login-link` — prints a `login.tailscale.com/a/…` link to send them (they must already be a tailnet member).

Per-user isolation on Incus: use `--project <dev>` to give each developer their own Incus project (they see only their instances). Note VMs on the shared `incusbr0` bridge can reach each other at L3 regardless of Tailscale ACLs — close that separately (per-project network or nftables) if network-level isolation matters. Incus does **not** mount the host filesystem into guests, so the `/mnt` exposure that the OrbStack setup has to switch off with `--isolated` does not exist here.

## Shared Claude login across a VM's users (optional)

`DEVSYS_SHARED_CLAUDE=1` (during install, or bake it into the base) makes every Unix user on a VM share **one** Claude Code login — sign in once, `root`/`soheb`/`nv`/… all use it. It creates a `devs` group + a group-owned `/opt/devsys/claude` and sets `CLAUDE_CONFIG_DIR` for all shells; `configure_user` enrols each dev user into `devs`.

- **Scope is per-VM, never across VMs.** Each developer signs into *their own* Claude account on *their own* VM. Do not share one login across the fleet (account-sharing + rate limits).
- **GitHub separation is unaffected.** Only Claude's own config (auth, agents, settings, plugins, history) is shared; `gh` (`~/.config/gh`) and `git` (`~/.gitconfig`) stay per-user, so `claude` run as `soheb` still commits/pushes as that user's GitHub account, and as `nv` as the other.
- **Shared means shared, both ways.** A plugin installed or a user-level setting changed by any user (root/soheb/nv) applies to all of them on that VM — the config dir is one copy, not per-user overlays. Project-level config (`.claude/settings.json`, `.mcp.json` inside a repo) stays with that project. Because Claude writes files `0600`, a `.path` unit (`devsys-claude-share.path`) re-grants group access the instant the shared dir changes, with a 1-minute timer as backstop, so a refreshed token or a newly installed plugin is readable by the other users right away.
- Bake it in: `curl … devsys-v3.sh | DEVSYS_UNATTENDED=1 DEVSYS_SHARED_CLAUDE=1 bash` during the base build; then sign in once per VM (`claude`). Retrofit a live VM: `sudo DEVSYS_SHARED_CLAUDE=1 DEVSYS_USER=<u> devsys install none`.
- **AI CLIs auto-update weekly, centrally.** Claude Code's own background updater is turned off (`DISABLE_AUTOUPDATER=1`, set for all shells by the toolchain env file) because it can't write the shared, root-owned mise store from a dev user's session and its silent updates re-triggered the onboarding wizard. Instead, a baked systemd timer (`devsys-ai-update.timer`, weekly with a randomized delay) runs `devsys update-ai` as root, which reinstalls the AI CLIs (`claude`/`codex`/`gemini`/`opencode`) at `@latest` for every user at once. The `NPM_AI` pins are just the baseline a fresh install / golden image ships with — you never bump them to stay current. Update on demand any time with `sudo devsys update-ai`; change the cadence by editing the timer. The first-run onboarding you complete after the initial sign-in sticks in the shared config across these updates.

## Commands (inside a VM)

`devsys install [groups…]` · `devsys --list` · `devsys mise …` / `devsys npm …` (manage the shared toolchain) · `devsys status` · `devsys logins` · `devsys ts-login` · `devsys backup`/`restore`/`reconfigure` (encrypted Tigris) · `devsys serve <port>` · `devsys fix-dns` · `devsys update` · `devsys update-ai` (reinstall AI CLIs at latest; a weekly timer runs this).

## Status

- **Validated on the Incus host `beehive`** (recorded in the runbook): golden image built and published; clones boot with the pinned toolchain and join Tailscale dual-tagged and non-ephemeral; admin and dev SSH both connect; per-dev isolation holds. Shared-Claude (3.1.1) was verified across root/soheb/nv on one VM.
- **Installer 3.2.0 has not been run on Incus.** It was tested on OrbStack only (a full 12-group build and a clone on Apple Silicon). Treat the next Incus base build as its validation pass.
- All scripts are `shellcheck`-clean.
