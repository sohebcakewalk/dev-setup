# myScripts

Collection of scripts.

| Path | What it is |
|---|---|
| [`claude-config/`](claude-config) | Keeps Claude Code user settings and plugins the same across machines and accounts |
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
git clone <this-repo-url> myScripts
cd myScripts/claude-config
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
cd myScripts/claude-config
./setup.sh save
git add settings.json
git commit -m "Update Claude settings"
git push
```

On every other machine or account:

```bash
cd myScripts
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
