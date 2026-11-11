# DevSys VM v2

Bootstrap for an **Ubuntu 24.04 LTS (noble)** development VM — that is the supported target; other recent Ubuntu/Debian releases generally work and only produce a warning. `newvm.sh` lets you pick the OrbStack image with `--distro ubuntu|debian` and `--release <codename>` (or asks interactively when run in a terminal); without a terminal it defaults to `ubuntu:noble`. Non-apt distributions are rejected because the bootstrap is apt-based. It is designed for a single command immediately after SSHing into a new VM:

```bash
curl -fsSL https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/devsys-vm.sh | bash
```

Run it as `root` if that is how the VM starts. The script installs OS packages and services, then installs the **shared developer toolchain once**, with **every tool version-pinned** so all VMs run an identical environment: binary tools (node, bun, python, ripgrep, bat, gh, lazygit, micro, …) at exact versions via mise (`MISE_TOOLS` in the script), JS CLIs (pnpm, neonctl, tigris, claude, codex, gemini, opencode) at exact versions via npm (`NPM_CLIS`). Homebrew's only job is delivering mise, because brew cannot pin exact versions. Everything is owned by a dedicated `linuxbrew` system account and shared by every user through shims on PATH. To change a version, edit the pins, publish, and rerun the toolchain stage on each VM (`devsys update`, then `sudo devsys install`). It then asks for a normal development username (or uses `DEVSYS_USER`), adds it to `sudo`, sets zsh, optionally connects Tailscale, and runs a light per-user stage (shell and AI config only) as that user — fully unattended. **To add another developer, just rerun the same command and give the new username: the toolchain is reused, so it takes seconds, not minutes.** Manage the shared toolchain with `devsys brew …` / `devsys npm …` (they run as the owning account; the live Brewfile is `/home/linuxbrew/.config/devsys/Brewfile`). Homebrew is never installed as root. The only interactive prompts in the root flow are the username, the new user's password, and the optional Tailscale connect; CLI logins happen afterwards, as the dev user, via `devsys logins`. (Deliberate design: a nested sudo password prompt deadlocks under a piped `curl | bash` handoff because sudo's default `use_pty` suspends it, so the user stage is engineered to never need sudo.)

Repeated runs are idempotent: apt and `brew bundle` skip what is installed, the Zsh changes live in a marked `# >>> devsys >>>` block (the original file is backed up once to `*.devsys.bak`), and a customized `~/.config/devsys/Brewfile` is preserved rather than overwritten.

## Publish

Upload the contents of [devsys-vm.sh](devsys-vm.sh) as the `devsys-vm.sh` file in the referenced Gist. The companion [Brewfile](Brewfile) is a reviewable copy of the package list; the script writes the same file to `/home/linuxbrew/.config/devsys/Brewfile` and installs it with `brew bundle`.

For a test Gist or branch, point the handoff at its raw URL (must be HTTPS; the script pins `--proto '=https' --tlsv1.2`):

```bash
export DEVSYS_SCRIPT_URL='https://example.invalid/devsys-vm.sh'
curl -fsSL "$DEVSYS_SCRIPT_URL" | bash
```

`DEVSYS_USER` preselects the development username and `DEVSYS_WORK_DIR` overrides the default `~/work` workspace.

For fully unattended provisioning (cloud-init, scripted VM creation): `DEVSYS_UNATTENDED=1` skips the terminal requirement, requires `DEVSYS_USER`, and creates the user with `--disabled-password` (Tailscale SSH or admin-installed keys are the front door; an unused password is just attack surface). `DEVSYS_TS_AUTHKEY` (a `tskey-auth-…` key — mint it non-ephemeral, preauthorized, and tagged) drives a non-interactive Tailscale connect, with optional `DEVSYS_TS_HOSTNAME` (default `hostname -s`) and `DEVSYS_TS_TAGS` (e.g. `tag:devsys`, unnecessary when the key itself is tagged). Without an auth key, unattended runs skip Tailscale with a warning instead of failing.

## Provisioning modes: admin mode vs developer mode

The companion [newvm.sh](newvm.sh) and [template.yaml](template.yaml) implement the provisioning pipeline for OrbStack — no local files needed, run fully remotely. There are two modes.

### Admin mode (default — recommended for managed team VMs)

The VM joins the tailnet automatically with an admin-minted key, **tagged** `tag:devsys` + `tag:<devuser>`. Tagged nodes never hit key expiry, the admin keeps root SSH on every VM, and per-developer isolation is enforced by SSH rules.

One-time setup:

1. **Tailscale → Settings → OAuth clients:** generate a client, scope **Auth Keys: Write**, tag `tag:devsys`. Store it in the provisioning Mac's Keychain:
   ```bash
   security add-generic-password -s ts-oauth -a tailscaleclientid -w '<client-id>'
   security add-generic-password -s ts-oauth -a tailscaleclientsecret -w '<client-secret>'
   ```
2. **Tailscale → Access controls → Tags (`tagOwners`):** `"tag:devsys": ["autogroup:admin", "tag:devsys"]` — the **self-ownership is required**: multi-tag keys demand that every tag, including `tag:devsys` itself, passes the ownership check, or the mint fails with "requested tags are invalid or not permitted". Plus one `"tag:<dev>": ["tag:devsys"]` per developer (ownership by `tag:devsys` is what lets the one OAuth client mint every dev tag).
3. **Tailscale → Access controls → Tailscale SSH:** `autogroup:member → autogroup:self` (users `nonroot`,`root`); `autogroup:admin → tag:devsys` (users `root`); and per developer `"<dev>@example.com" [+ tag:<dev> if their laptop is tagged] → tag:<dev>` (users `root`,`<dev>`). Never use `tag:devsys` as a **source** — it would let every VM reach every other VM.
4. Provisioning Mac: OrbStack + `jq` installed.

Per VM (nothing to change in the console for an existing developer):

```bash
curl -fsSL https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/newvm.sh | bash -s -- <vmname> <devuser>
```

`newvm.sh` reads the Keychain credentials, mints a single-use, 1-hour, preauthorized key tagged `tag:devsys` + `tag:<devuser>`, renders the cloud-init template from this gist, and creates the VM **isolated by default** (`--isolated --isolate-network`), which bootstraps itself unattended on first boot.

> **Filesystem isolation (important).** By default OrbStack shares the host's home (`/mnt/mac`) and every other machine's filesystem (`/mnt/machines/<vm>`) into each VM — so without isolation one developer could read another's files from inside their own VM, defeating the Tailscale-layer isolation. `newvm.sh` therefore passes `--isolated --isolate-network`, which removes those mounts and blocks LAN/host-IP access while leaving the internet, Tailscale, and the `<user>@<vm>@orb` proxy fully working. Pass `--shared` to opt back into host file sharing for a specific VM. **Existing non-isolated VMs cannot be converted in place — recreate them** to gain isolation.

### Developer mode (`--login-link` — dev-owned VMs, no admin key)

The VM is created with **no auth key**; the developer joins it to the tailnet with their own Tailscale account via a browser link and becomes the node's owner. No per-dev tags or SSH rules are needed — the standard `autogroup:member → autogroup:self` rule gives them (and only them) SSH automatically.

One-time setup: **invite the developer to your tailnet** (Users → Invite). That's mandatory — the link authenticates the machine as whoever signs in, so a non-member's login would move the VM into *their personal* tailnet.

Per VM:

```bash
curl -fsSL https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60/raw/newvm.sh | bash -s -- <vmname> <devuser> --login-link
```

`newvm.sh` waits for the VM to install Tailscale (1–3 minutes) and **prints the `https://login.tailscale.com/a/…` link itself** — send it to the developer; the link stays valid until used. If the wait times out, fetch it manually: `ssh root@<vmname>@orb devsys ts-login` (works standalone on any VM whose Tailscale is not yet connected). After the node appears in Machines, **disable key expiry** on it (user-owned nodes expire after ~180 days otherwise).

### Choosing a mode

| | Admin mode | Developer mode |
| --- | --- | --- |
| Tailnet setup per dev | tag + 1 SSH rule | none (just the invite) |
| Admin SSH to the VM | ✅ via `tag:devsys` | ❌ (`ssh root@<vm>@orb` on the host Mac only) |
| Key expiry | never (tagged) | ~180 days unless disabled per node |
| Provisioning | fully zero-touch | dev must click the link once |
| Node owner | tailnet (tagged) | the developer |

Rule of thumb: admin mode for VMs you manage and maintain; developer mode for quick onboarding or VMs that should be genuinely private to the developer.

## Commands

After installation, `devsys` is installed at `/usr/local/bin/devsys`:

| Command | Purpose |
| --- | --- |
| `devsys install` | Root: system stage + user handoff. Non-root: user stage. |
| `devsys system-install` | Root-only apt packages, Redis, Tailscale service. |
| `devsys user-install` | Per-user Zsh/Starship/direnv and AI config (shared toolchain must exist). |
| `devsys brew …` / `devsys npm …` | Manage the shared toolchain as its owner (e.g. `devsys brew install deno`). |
| `devsys ts-login` | Print a Tailscale login link for a developer; the VM joins under whoever signs in. |
| `devsys status` / `devsys logins` | Tool versions, service state, CLI login state. |
| `devsys backup` / `devsys restore` | Encrypted configuration backup to/from Tigris. |
| `devsys reconfigure` | (Re-)enter Tigris credentials and bucket. |
| `devsys reset` | Remove devsys config and, optionally, CLI auth files (double-confirmed). |
| `devsys serve 3000` / `serve off 3000` / `serve status` | Tailscale HTTPS serve for a local port. |
| `devsys fix-dns` | Replace `/etc/resolv.conf` with 1.1.1.1/8.8.8.8 after confirmation (backs up the original). |
| `devsys update` | Download the published script, syntax-check it, and reinstall itself. |

## Backup security

Credentials, SSH keys, and AI-tool authentication are user-specific. `backup` stages the selected dotfiles (plus the workspace, when it is under the home directory, excluding `node_modules`), encrypts the tarball locally with `openssl enc -aes-256-cbc -pbkdf2 -iter 200000` before upload, and keeps one previous version per backup name. The passphrase is read from the terminal and passed to OpenSSL via the environment, never on a command line. The backup contains private SSH keys and CLI tokens: protect the passphrase and the Tigris access key accordingly, and treat `~/.config/devsys/tigris.env` (mode 600) as a secret.

Known limitation: `tigris login credentials` receives the access key and secret as command-line arguments because the CLI offers no environment/stdin alternative; on a single-user VM this is a momentary `ps` exposure during `reconfigure` only.
