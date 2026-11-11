# DevSys VM — OrbStack golden clone (Mac Studio)

This folder runs the devsys toolchain on a **Mac with OrbStack**. For an Ubuntu server with Incus, use `../devsys-incus`. Only the host side differs between the two:

- The in-guest installer `devsys-vm.sh` is host-agnostic: the same file (3.3.0) sits in both folders.
- `build-base.sh` and `newvm.sh` are rewritten for `orbctl`.
- `template.yaml` is gone: `orbctl clone` takes no cloud-init, so `newvm.sh` runs the per-clone setup itself.

The workflow is still a **golden image**: install the toolchain once into a base machine, then every dev VM is a clone that is ready in about 20 seconds.

## Files

| File | Runs on | Purpose |
| --- | --- | --- |
| `build-base.sh` | the Mac | create the base machine, install the toolchain, generalize it, stop it |
| `newvm.sh` | the Mac | clone a dev VM from the base, mint a tagged Tailscale key, join the tailnet |
| `devsys-vm.sh` | inside the guest | the grouped, pinned installer and the `devsys` command (3.3.0) |
| `devsys-orbstack-runbook.pdf` | — | the step-by-step runbook |
| `make-runbook.py` | the Mac | rebuilds the runbook PDF (needs `reportlab`) |

## What differs from the Incus setup

| Concern | Incus (`devsys-incus`) | OrbStack (this folder) |
| --- | --- | --- |
| Host | bare-metal Ubuntu server | Mac Studio, Apple Silicon (arm64 guests) |
| Guest type | full virtual machine | OrbStack machine (shared kernel, lighter isolation) |
| Golden image | published image `devsys-base` | the **stopped** machine `devsys-base` itself |
| Per-clone config | cloud-init user-data | `newvm.sh` runs `devsys install none` in the clone |
| Auth key delivery | written into cloud-init, removed from the instance config after first boot | piped on stdin, never stored |
| OAuth creds | mode-600 file | env, mode-600 file, or macOS Keychain |
| Host filesystem | never mounted | hidden by `--isolated` (inherited by clones) |
| Per-dev projects | `--project <dev>` | not available |

OrbStack machines share one Linux kernel, so the separation between developers is weaker than between Incus VMs. Tailscale ACLs stay the front door.

## What a developer can and cannot reach

Checked on OrbStack 2.2.4 with a base and two clones, as root inside a clone:

| From inside a VM | Result | What enforces it |
| --- | --- | --- |
| The Mac's files (`/mnt/mac`, `/Users`, `/Volumes`) | not present | `--isolated` |
| Other VMs' files (`/mnt/machines`) | not present | `--isolated` |
| Mac commands (`mac`, `open`, `pbcopy`), the Mac's SSH agent, the Docker socket | not available | `--isolated` |
| A port on another VM | blocked | the inbound firewall in each VM (installer 3.3.0) |
| Services on the Mac, through the Mac's LAN address | **reachable** | nothing — see below |
| The internet | reachable | intended |

`--isolate-network` alone does not separate the VMs: with it set, one clone still opened a TCP connection to another, and to the Mac's LAN address. Only OrbStack's own host names (`host.orb.internal`, the gateway) were blocked. So each VM carries its own firewall:

- It drops new incoming connections on every interface except Tailscale (`tailscale0`) and loopback. Outgoing traffic is untouched.
- It is baked into the base, enabled at boot, and shown by `devsys status`. The rules are in `/etc/devsys/firewall.nft`, in their own nftables table.
- A dev server is therefore reachable over Tailscale (`devsys serve <port>`, or the VM's tailnet address) and not from other VMs. It is also not reachable from the Mac at `<vm>.orb.local`.
- `DEVSYS_FIREWALL=0 ./build-base.sh` builds a base without it.

What is left open:

- **The Mac's own network services.** A VM can connect to anything the Mac offers on its LAN address (Remote Login, Screen Sharing, File Sharing). Turn off the ones you do not need in System Settings → General → Sharing.
- **Root inside the VM.** Every developer has passwordless `sudo`, so they can stop their own firewall. That exposes only their own VM; it does not open anyone else's. Two users on one VM can read each other's files.
- **The shared kernel.** OrbStack says isolated machines "aren't a full security boundary". Use the Incus setup when developers must be strongly separated.
- **Tailscale's network policy.** The SSH rules decide who can log in. Whether one VM can reach another's ports over the tailnet is decided by the tailnet's access rules, which allow everything by default.

## One-time: build the golden base

Requires OrbStack and `jq` (ships with current macOS).

```bash
./build-base.sh
```

This creates `devsys-base` from `ubuntu:resolute` (Ubuntu 26.04 LTS, isolated), installs every group with no dev user and no Tailscale login, clears the per-machine identity (machine-id, Tailscale state, SSH host keys), and stops the machine.

**The stopped base is the image.** Do not start it by hand — a running base regenerates the identity that clones must not share, and `newvm.sh` refuses to clone it. To change it, re-run `build-base.sh`.

Options, as environment variables:

| Variable | Effect |
| --- | --- |
| `DEVSYS_GROUPS="node python ai"` | install only these groups into the base |
| `DEVSYS_SHARED_CLAUDE=1` | bake in the shared-Claude setup (see `../devsys-incus/README.md`) |
| `DEVSYS_BASE_IMAGE=ubuntu:noble` | use another distro image for a new base, here Ubuntu 24.04 LTS (default: `ubuntu:resolute`, 26.04 LTS) |
| `DEVSYS_SCRIPT_FILE=…` | local installer to use (default: `devsys-vm.sh` next to the script) |
| `DEVSYS_SCRIPT_URL=…` | installer URL, used when there is no local installer |
| `DEVSYS_ORB_USER=orbadmin` | name of OrbStack's built-in default user |

A different base name is the first argument: `./build-base.sh devsys-base-next`.

To bump tool versions later: edit the `MISE_*`/`NPM_*` pins in `devsys-vm.sh` and re-run `./build-base.sh`. Existing clones are not touched.

### Installer 3.2.0 — republish the gist

3.2.0 adds a set of conveniences taken from [amitpareek/devsys](https://github.com/amitpareek/devsys):

- **Packages:** `wget`, `vim`, `less`, `locales`, `bash-completion` (base) and system `python3-pip` + `python3-venv` (build).
- **Mac locale fix:** a Mac's SSH client forwards `LC_CTYPE=UTF-8`, which is not a valid locale on Linux and makes `locale`, perl and bash print warnings. The base group compiles a locale named `UTF-8` so the value is valid. `DEVSYS_FIX_LOCALE=0` skips it.
- **Shell setup for every user, zsh and bash:** history settings, fzf key bindings (Ctrl-R, Ctrl-T), starship, direnv and the aliases now live in `/etc/devsys/rc.zsh` and `/etc/devsys/rc.bash`, so root and any account added later get them too. A login that starts in `$HOME` lands in `~/work`. In bash, Ubuntu's default `~/.bashrc` runs afterwards and still overrides the `ls`/`ll` aliases and the history size; zsh, the dev users' shell, is unaffected.
- **Completions** for `gh`, `flyctl`, `starship` and `tailscale`, generated system-wide.
- **`$EDITOR`** defaults to micro, then nano, then vim, unless you set one.
- **tmux:** mouse mode on, and `z`, an arrow-key session/window picker. `z` is downloaded from that repository, pinned to one commit and a SHA-256 checksum.

Left out on purpose: `openssh-server` (Tailscale SSH is the front door), and the optional `dotnet`, `docker`, `notes`, `ai-yolo` groups, `devsys-auth` and Taildrive.

It also carries the **3.1.7 fix**, which matters more:

With 3.1.6, a default install **silently skipped the `node`, `python`, `cloud` and `ai` groups and still printed "Done"**. The `mise` group writes `/etc/zsh/zshenv` before the `shell` group installs the zsh package, so dpkg stopped to ask which version of that file to keep. Its prompt read the rest of the group list from stdin as the answer, and the install loop ended early.

3.1.7 makes `apt-get` keep existing config files without asking and never read stdin, and shields the group loop's stdin. It also fixes `devsys status` reporting ripgrep as missing (it looked for `ripgrep`; the binary is `rg`).

`build-base.sh` uses the `devsys-vm.sh` beside it, so the OrbStack flow works as it stands. The gist still serves 3.1.6 as `devsys-v3.sh`, which matters in two places until it is republished:

- `devsys update` inside a VM downloads the gist copy and puts 3.1.6 back (a firewall that is already installed stays in place).
- The Incus flow (`curl … devsys-v3.sh | bash`) runs the same code. The skip was reproduced on OrbStack only; check an Incus base with `devsys status` before trusting it.

## One-time: Tailscale setup

Tags, `tagOwners`, and Tailscale SSH rules are **identical to the Incus setup** — see the runbook PDF in this folder, or `../devsys-incus/README.md`.

The OAuth client (scope Auth Keys: Write) lets `newvm.sh` mint one auth key per VM. Tagging it `tag:devsys` should be enough for every developer, because `tag:devsys` owns itself and each `tag:<dev>`; this follows Tailscale's documentation and has not been run here. Only the place the client is stored differs from Incus. `newvm.sh` looks in this order:

1. `DEVSYS_TS_CLIENT_ID` / `DEVSYS_TS_CLIENT_SECRET` in the environment
2. `~/.config/devsys/ts-oauth.env` (mode 600), the same file the Incus host uses
3. the macOS Keychain (the items the earlier OrbStack scripts used):
   ```bash
   security add-generic-password -s ts-oauth -a tailscaleclientid -w '<id>'
   security add-generic-password -s ts-oauth -a tailscaleclientsecret -w '<secret>'
   ```

## Per developer: clone a VM

```bash
./newvm.sh beehivekk bh
```

Mints a single-use key tagged `tag:devsys` + `tag:bh`, clones `devsys-base`, creates the `bh` user, and joins Tailscale. Reach it as `ssh bh@beehivekk` over the tailnet.

- `--login-link` — no admin key; prints a `login.tailscale.com/a/…` link for the developer (they must already be a tailnet member).
- `--base NAME` — clone from a different base machine.

The VM joins with `--accept-dns=false`, so it keeps its own DNS and MagicDNS cannot break ordinary lookups such as npm. Turn it on for one VM with `tailscale set --accept-dns=true` inside it.

### A second user on the same VM

```bash
orbctl run -m beehivekk -u root env DEVSYS_UNATTENDED=1 DEVSYS_USER=admin devsys install none
```

This adds `admin` beside `bh` with the same shell setup and tools, and leaves Tailscale alone. Add the username to the Tailscale SSH rule of whoever logs in as it. Every user created this way has passwordless `sudo`; to make one an ordinary user:

```bash
orbctl run -m beehivekk -u root bash -c 'rm -f /etc/sudoers.d/90-devsys-bh; gpasswd -d bh sudo'
```

That user can then no longer run the `devsys` subcommands that need root. These two commands have not been run on OrbStack.

Break-glass from the Mac: `orbctl run -m beehivekk -u root bash`. Retire a VM: `orbctl delete beehivekk`, then remove it from Tailscale → Machines.

## Moving a developer over from the Incus server

The Incus VM cannot be imported: `orbctl import` only reads OrbStack's own exports, and if the server is x86 its binaries do not run natively on Apple Silicon anyway. Build the VM fresh with `newvm.sh`, then copy the developer's files.

The Tailscale ACL does not let one VM SSH into another, so stream through an admin machine that can reach both as root:

```bash
ssh root@<old-vm> 'tar -C /home/bh --exclude=node_modules --exclude=.venv --exclude=.cache -czf - .' \
  | ssh root@<new-vm> 'tar -C /home/bh -xzpf -'
```

- Give the new VM a different Tailscale name while both exist (or it is registered as `<name>-1`). After the old one is retired and removed from Tailscale, rename with `tailscale set --hostname=<name>` inside the VM.
- `node_modules` and `.venv` hold architecture-specific binaries; reinstall them in each repo afterwards.
- If the old VM used shared Claude, copy `/opt/devsys/claude` the same way.
- Do **not** copy `/opt/devsys/mise`, `/var/lib/tailscale`, or `/etc/machine-id`.

These migration commands are a recipe; they have not been run against the Incus server.

## Status

Tested on an Apple Silicon Mac (M1 Pro, OrbStack 2.2.4, stock macOS bash 3.2), not yet on the Mac Studio:

- `build-base.sh` built a fresh base with **all 12 groups** in about 3 minutes (3.4 GB), with installer 3.1.7 and again with 3.2.0. Every pinned tool resolved an arm64 build.
- `newvm.sh --login-link` cloned it in 6 seconds. The clone had its own hostname and machine-id, the dev user with zsh and passwordless sudo, no `/mnt/mac`, Redis active, and `devsys status` showed every tool at its pinned version.
- The 3.2.0 additions were checked in a clone: `LC_CTYPE=UTF-8` no longer produces locale warnings (it did on the stock image); zsh and bash both get starship, direnv, fzf key bindings and the `gh`/`flyctl`/`tailscale` completions; a login from `$HOME` lands in `~/work`; `$EDITOR` is micro; `z` matches its pinned checksum.
- The guard paths (existing VM name, running base, bad name, missing base, missing OAuth client) all stop before anything is cloned.

- Installer 3.3.0: a full base built with all 12 groups, and two clones made with `newvm.sh --login-link`. Each clone's connection to a listening port on the other was refused, in both directions; with one firewall stopped the connection went through, and it was refused again once restarted. The firewall came back after a machine restart. Loopback, DNS, outbound HTTPS and Redis kept working, and `devsys status` showed every tool.
- Ubuntu 26.04 LTS (`ubuntu:resolute`, the default since this change): the same full build and two clones. All 12 groups installed, the dev user got zsh and passwordless `sudo` (26.04 ships `sudo-rs`), the locale fix and the firewall behaved as on 24.04, and `devsys status` showed every tool. The earlier results in this list were on 24.04.

Not tested:

- **Key mode** — minting a real Tailscale key and joining the tailnet. That code is carried over from the Incus `newvm.sh`.
- **The firewall with a joined VM.** The test clones were not on a tailnet, so Tailscale SSH and `devsys serve` through the firewall were not exercised. The rules accept everything on `tailscale0`.
- `DEVSYS_SHARED_CLAUDE=1` on OrbStack.
- The migration recipe above.

All three scripts are `shellcheck`-clean.
