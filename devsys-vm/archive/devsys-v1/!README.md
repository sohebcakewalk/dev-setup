# devsys-vm

One script to turn a fresh Ubuntu/Debian VM into a fully-loaded dev box — same toolset as [amitpareek/devsys](https://github.com/amitpareek/devsys), but installed directly on a machine (OrbStack Linux machine, a cloud VPS, a Fly.io/Railway box) instead of a container. It also wires up Tailscale + Redis to survive reboots, and gives you encrypted off-VM backup/restore of all your CLI logins and configs via [Tigris](https://www.tigrisdata.com/) object storage — so you can rebuild an identical box anywhere with three secrets.

## Install

```sh
curl -fsSL https://gist.githubusercontent.com/sohebcakewalk/dee2808e92831d35fadf30492e4f5711/raw/devsys-vm.sh | bash
```

The installer is an interactive wizard — every step is retryable or skippable, and it's safe to re-run (already-installed tools are detected and skipped). It also installs itself as a permanent `devsys` command at `/usr/local/bin/devsys`.

On a machine you've backed up before, the wizard offers **restore-first**: pull your encrypted bundle from Tigris, get all your logins back, then finish the install — identical box, no re-authenticating seven CLIs.

## What you get

- **Base tooling** — git, curl, build-essential, zsh, tmux, jq, htop, ncdu, ripgrep, fd, bat, eza, fzf, direnv, age, openssl, postgresql-client
- **Runtimes** via [mise](https://mise.jdx.dev/) — Node LTS, Python 3.12, plus Bun and pnpm
- **CLIs** — gh, flyctl, neonctl, tigris, claude (Claude Code), gemini, codex, opencode, lazygit, glow, starship
- **Services** — Redis and Tailscale (official repo), both enabled via systemd to survive reboots; a `devsys-boot` unit re-asserts `tailscale up --ssh` on every boot
- **Shell** — zsh as default shell with sensible aliases (eza/bat/lazygit), starship prompt, mise + direnv hooks, `~/work` as your project home
- **AI zero-prompt configs** — Claude Code, Codex, and Gemini pre-configured to skip permission prompts (built for disposable VMs; see security notes)

## Commands

| Command | What it does |
|---|---|
| `devsys install` | Interactive setup wizard (default when run with no args) |
| `devsys logins` | Auth status for every CLI + the exact login command for each |
| `devsys backup` | Encrypt & upload your auth/config snapshot to Tigris |
| `devsys restore` | Download & restore the snapshot, then offer to re-clone your repos |
| `devsys status` | Health check: Tailscale, Redis, tool versions, last backup |
| `devsys serve [port]` | Expose a local port over Tailscale HTTPS and print the URL |
| `devsys reset` | Wipe devsys config, optionally CLI auths and the remote bundle |
| `devsys update` | Re-fetch the latest script from this gist |

## Backup & restore

`devsys backup` snapshots your CLI credentials and dotfiles (`.claude`, `.codex`, `.gemini`, `.config/gh`, `.fly`, `.config/neonctl`, `.gitconfig`, SSH keys/config, `.zshrc`/`.zshenv`) plus a manifest of every git repo under `~/work`. The bundle is encrypted locally with a passphrase (AES-256-CBC, PBKDF2, 200k iterations) before upload — Tigris only ever sees ciphertext. The previous bundle is kept as a `.prev` copy on every upload.

To rebuild anywhere, you need exactly **three secrets**:

1. Tigris Access Key ID
2. Tigris Secret Access Key
3. Your encryption passphrase

Run the installer on a fresh VM, choose restore-first, enter those three, and `devsys restore` puts your logins back and offers to re-clone every repo from the manifest.

## Requirements

- Ubuntu/Debian (needs `apt-get`) on amd64 or arm64
- Root or passwordless-capable `sudo`
- A TTY — the wizard prompts via `/dev/tty`, so it works fine under `curl | bash`
- Optional: a [Tailscale](https://tailscale.com/) account (a reusable auth key is easiest for headless boxes) and a [Tigris](https://www.tigrisdata.com/) bucket for backups

## Security notes

- The AI CLI configs disable approval prompts (`bypassPermissions`, `danger-full-access`, `--yolo`). That's the point on a disposable, single-purpose VM — but don't run this on a machine holding anything you can't afford an agent to touch.
- Backups include your **SSH private keys** and CLI credentials. Choose a strong passphrase; anyone with the bundle + passphrase is you.
- Existing dotfiles (`.zshrc`, `.zshenv`, etc.) are backed up once to `<file>.devsys.bak` before being overwritten.
- As with any `curl | bash`, read the script first — it's a single file, and that's what this gist is for.

## Tips

- **MagicDNS:** the wizard asks before routing DNS through your tailnet — on restrictive tailnets this can break outbound DNS (npm, Tigris). Default is off; you can flip it later with `sudo tailscale set --accept-dns=true`.
- **`devsys serve`** with no port lists everything listening and asks which one to expose. Needs MagicDNS + HTTPS certificates enabled in your Tailscale admin console.
- **Re-running is cheap:** `devsys install` again after a partial failure just fills in the gaps.