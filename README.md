# dev-setup

Scripts for setting up development machines and VMs.

| Path | What it is |
|---|---|
| [`claude-config/`](claude-config) | Keeps Claude Code user settings and plugins the same across machines and accounts |
| [`devsys-vm/`](devsys-vm) | Builds identical developer VMs from one golden image, on an Incus server or on a Mac with OrbStack |
| [`generate-icons.sh`](generate-icons.sh) | Resizes `logo.png` into app icons from 48px to 512px using `sips` (macOS) |

## claude-config/ — sync Claude Code settings and plugins

Use this to get the same Claude Code setup everywhere: a new or reset Mac, a VM, or a second user account.

### The two files

**`claude-config/settings.json`** — a copy of the user-level Claude Code settings file (`~/.claude/settings.json`). It holds:

- which plugins are enabled (`enabledPlugins`)
- extra plugin marketplaces (`extraKnownMarketplaces`)
- the status line command, permission mode and UI preferences

It only *lists* plugins. It does not contain the plugin code, logins or tokens.

**`claude-config/setup.sh`** — copies that file into place and installs everything it lists. It has two modes:

| Command | What it does |
|---|---|
| `./setup.sh apply` (default) | Copies `settings.json` to `~/.claude/settings.json`, adds the plugin marketplaces, and installs every enabled plugin at user scope. An existing, different `settings.json` is first saved as `settings.json.bak-<date>-<time>`. |
| `./setup.sh save` | Copies this machine's `~/.claude/settings.json` back into this folder so you can commit it. |

### Requirements

- `claude` (Claude Code CLI) on your `PATH`, and signed in
- `python3`
- `git`, to clone this repo

### Set up a new machine or account

```bash
git clone https://github.com/sohebcakewalk/dev-setup.git
cd dev-setup/claude-config
./setup.sh apply
```

Then restart Claude Code.

To see what it would do without changing anything:

```bash
DRY_RUN=1 ./setup.sh apply
```

### Keep machines in sync

On the machine where you changed settings or plugins:

```bash
cd dev-setup/claude-config
./setup.sh save
git add settings.json
git commit -m "Update Claude settings"
git push
```

On every other machine or account:

```bash
cd dev-setup
git pull
cd claude-config
./setup.sh apply
```

### What is not synced

- **Logins.** Sign in to Claude and re-authorise connectors once on each machine and account.
- **Account connectors** (for example ClickUp, Microsoft 365). These follow the Claude account you sign in with, not this repo.
- **The status line program.** `settings.json` runs `claude-statusline`; install it separately (on this Mac it came from Homebrew) or the status line stays empty.
- **Personal skills, memory and chat history** under `~/.claude/`. Copy those by hand if you need them.
- **Removals.** `apply` installs plugins but never uninstalls one you removed from `settings.json`; run `claude plugin uninstall <name>` on each machine.

### Notes

- `settings.json` sets `permissions.defaultMode` to `auto` and `skipDangerousModePermissionPrompt` to `true`. Change these in the file before running `apply` somewhere you want Claude to ask before acting.
- A marketplace that is not the official one must also be listed in `MARKETPLACES` at the top of `setup.sh`, otherwise its plugins fail to install on a fresh machine.
- If Claude Code uses a non-default config folder, set `CLAUDE_CONFIG_DIR` and the script will use it.

## devsys-vm/ — developer VMs from a golden image

Use this to give each developer a Linux VM with the same pinned toolchain. The toolchain is installed once into a base VM; every developer VM is then a clone of that base, ready in seconds, and joins Tailscale under its own tag.

### Pick the folder for your host

| Folder | Host | Guest |
|---|---|---|
| [`devsys-vm/devsys-incus/`](devsys-vm/devsys-incus) | Bare-metal Ubuntu server running Incus | Full virtual machine |
| [`devsys-vm/devsys-orbstack/`](devsys-vm/devsys-orbstack) | Mac with OrbStack (Apple Silicon) | OrbStack machine (shared kernel, lighter isolation) |

Each folder has its own README with the full steps. Both folders also have a PDF runbook.

[`devsys-vm/archive/`](devsys-vm/archive) keeps the earlier versions (`devsys-v1`, and the Homebrew-based `devsys-v2`) for reference, plus `make-runbook.py`, which builds the Incus runbook PDF (the OrbStack one is built by the `make-runbook.py` in its own folder). Do not use the archived scripts for new VMs.

### The scripts

| File | Runs on | What it does |
|---|---|---|
| `devsys-vm.sh` | inside the VM | Installs the toolchain by group (`base`, `cli`, `node`, `python`, `ai`, …) with every version pinned, and provides the `devsys` command. The file is identical in both folders. |
| `build-base.sh` | the host | Builds the golden base and clears its machine identity so clones do not collide |
| `newvm.sh` | the host | Clones a VM for one developer, creates their user and joins Tailscale |
| `template.yaml` | Incus only | Per-clone cloud-init (hostname, user, Tailscale join) |

### Quick start

Build the base once, then clone a VM per developer:

```bash
cd dev-setup/devsys-vm/devsys-orbstack   # or devsys-incus
./build-base.sh
./newvm.sh <vm-name> <dev-user>
```

On Incus the base build has manual steps first (create the base VM, run the installer inside it); follow [`devsys-incus/README.md`](devsys-vm/devsys-incus/README.md).

### Requirements

- Incus host: Incus (`incus admin init` done) and `jq`
- Mac host: OrbStack and `jq`
- A Tailscale tailnet with the tags and SSH rules described in the folder READMEs, and an OAuth client to mint auth keys

### Notes

- The scripts download the installer from a GitHub gist, not from this repo. After you change `devsys-vm.sh`, republish it to the gist (as `devsys-v3.sh`) before the next base build, or set `DEVSYS_SCRIPT_URL` to another location.
- Keep the two copies of `devsys-vm.sh` identical when you edit one.
- Developer users are created without a password and with passwordless `sudo`: each developer has full root on their own VM.
