#!/usr/bin/env bash
# Sync Claude Code user settings + plugins between machines / accounts.
#
#   ./setup.sh apply   copy settings.json from this folder into ~/.claude and install plugins (default)
#   ./setup.sh save    copy this machine's ~/.claude/settings.json back into this folder
#
# Set DRY_RUN=1 to print what would happen without changing anything.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/settings.json"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
MODE="${1:-apply}"

# Marketplaces that are not the built-in official one.
MARKETPLACES=(
  "obra/superpowers-marketplace"
  "nextlevelbuilder/ui-ux-pro-max-skill"
  "warpdotdev/claude-code-warp"
)

run() {
  if [ "${DRY_RUN:-}" = "1" ]; then echo "would run: $*"; else "$@"; fi
}

case "$MODE" in
  save)
    run cp "$DEST" "$SRC"
    echo "Saved $DEST -> $SRC (commit and push it to share)."
    exit 0
    ;;
  apply) ;;
  *) echo "usage: $0 [apply|save]" >&2; exit 2 ;;
esac

command -v claude >/dev/null || { echo "claude CLI not found on PATH; install it first." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is needed to read settings.json." >&2; exit 1; }

# 1. settings.json (keep a dated copy of whatever was there)
run mkdir -p "$(dirname "$DEST")"
if [ -f "$DEST" ] && ! cmp -s "$SRC" "$DEST"; then
  run cp "$DEST" "$DEST.bak-$(date +%Y%m%d-%H%M%S)"
fi
run cp "$SRC" "$DEST"

# 2. marketplaces
for m in "${MARKETPLACES[@]}"; do
  run claude plugin marketplace add "$m" || echo "  (marketplace $m: already added or failed, continuing)"
done

# 3. every plugin enabled in settings.json
python3 -I - "$SRC" <<'PY' | while read -r plugin; do
import json, sys
for name, on in json.load(open(sys.argv[1])).get("enabledPlugins", {}).items():
    if on:
        print(name)
PY
  run claude plugin install "$plugin" --scope user </dev/null || echo "  (plugin $plugin: install failed, continuing)"
done

command -v claude-statusline >/dev/null || echo "Note: 'claude-statusline' is not installed here, so the status line will be empty until you install it."
echo "Done. Restart Claude Code to pick up the changes."
