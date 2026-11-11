#!/usr/bin/env python3
"""Build the Incus runbook PDF.  Needs reportlab:
    python3 make-runbook.py ../devsys-incus/devsys-incus-runbook.pdf
"""
import re
import sys
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import (
    CondPageBreak, HRFlowable, KeepTogether, Paragraph, Preformatted, SimpleDocTemplate, Spacer, Table, TableStyle,
)

TITLE = "DevSys VM — Incus Golden-Image Runbook"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("devsys-incus-runbook.pdf")

TEAL = colors.HexColor("#0d9488")
TEAL_DARK = colors.HexColor("#0f766e")
INK = colors.HexColor("#1e293b")
MUTED = colors.HexColor("#475569")
GRID = colors.HexColor("#cbd5e1")
HEAD_BG = colors.HexColor("#ccfbf1")
ROW_ALT = colors.HexColor("#f0fdfa")
CODE_BG = colors.HexColor("#f1f5f9")
WARN = colors.HexColor("#c2410c")
GOOD = colors.HexColor("#15803d")

MARGIN = 57
WIDTH = A4[0] - 2 * MARGIN - 12  # the frame pads flowing text 6pt each side

body = ParagraphStyle("body", fontName="Helvetica", fontSize=9.5, leading=13.5, textColor=INK, spaceAfter=5)
styles = {
    "title": ParagraphStyle("title", fontName="Helvetica", fontSize=22, leading=27, textColor=INK, spaceAfter=3),
    "subtitle": ParagraphStyle("subtitle", parent=body, fontSize=11, leading=15, textColor=MUTED, spaceAfter=8),
    "h1": ParagraphStyle("h1", fontName="Helvetica", fontSize=15, leading=19, textColor=TEAL_DARK,
                         spaceBefore=12, spaceAfter=6, keepWithNext=True),
    "h2": ParagraphStyle("h2", fontName="Helvetica", fontSize=11, leading=14, textColor=INK,
                         spaceBefore=7, spaceAfter=3, keepWithNext=True),
    "body": body,
    "step": ParagraphStyle("step", parent=body, leftIndent=22, firstLineIndent=-12),
    "cell": ParagraphStyle("cell", parent=body, fontSize=8.5, leading=11.5, spaceAfter=0),
    "head": ParagraphStyle("head", parent=body, fontSize=8.5, leading=11.5, spaceAfter=0, textColor=TEAL_DARK),
    "warn": ParagraphStyle("warn", parent=body, textColor=WARN),
    "good": ParagraphStyle("good", parent=body, textColor=GOOD),
    "code": ParagraphStyle("code", fontName="Courier", fontSize=8, leading=10.5, textColor=INK),
}


def markup(text):
    """`code` and **bold** in plain text -> ReportLab paragraph markup."""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"`([^`]+)`", r'<font face="Courier" color="#0f766e">\1</font>', text)
    return re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)


def p(text, style="body"):
    para = Paragraph(markup(text), styles[style])
    return KeepTogether([para]) if style in ("warn", "good") else para


def code(text):
    indent = 36
    block = Table([[Preformatted(text.strip("\n"), styles["code"])]], colWidths=[WIDTH - indent], hAlign="RIGHT")
    block.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), CODE_BG),
        ("BOX", (0, 0), (-1, -1), 0.5, GRID),
        ("LEFTPADDING", (0, 0), (-1, -1), 8), ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    return KeepTogether([block, Spacer(1, 5)])


def table(rows, widths):
    data = [[p(c, "head") for c in rows[0]]] + [[p(c, "cell") for c in r] for r in rows[1:]]
    t = Table(data, colWidths=[w * WIDTH for w in widths], hAlign="LEFT", repeatRows=1)
    style = [
        ("BACKGROUND", (0, 0), (-1, 0), HEAD_BG),
        ("GRID", (0, 0), (-1, -1), 0.5, GRID),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7), ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]
    style += [("BACKGROUND", (0, i), (-1, i), ROW_ALT) for i in range(2, len(data), 2)]
    t.setStyle(TableStyle(style))
    return KeepTogether([t, Spacer(1, 5)])


def page_frame(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(TEAL)
    canvas.rect(0, A4[1] - 24, A4[0], 24, stroke=0, fill=1)
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(MUTED)
    canvas.drawString(MARGIN, 30, TITLE)
    canvas.drawRightString(A4[0] - MARGIN, 30, f"Page {doc.page}")
    canvas.restoreState()


story = [
    p(TITLE, "title"),
    p("Identical, version-pinned Ubuntu dev VMs on a bare-metal Incus host — build one golden image, "
      "clone per developer in seconds, isolated over Tailscale.", "subtitle"),
    HRFlowable(width="100%", thickness=1, color=TEAL, spaceAfter=9),

    p("The system: three files on a bare-metal Ubuntu server running Incus — `devsys-vm.sh`, `newvm.sh` and "
      "`template.yaml` in the `devsys-incus` folder, published in the gist as `devsys-v3.sh`, `newvm-v3.sh` and "
      "`template-v3.yaml`. You install the pinned toolchain once into a base VM, publish it as the image "
      "`devsys-base`, and every developer VM is a ~5-second clone. No Homebrew (mise installed directly, "
      "system-wide, as root); tools chosen by group, every version pinned. Each clone auto-joins Tailscale tagged "
      "`tag:devsys` + `tag:<dev>`; the admin reaches everything, each dev reaches only their own VM."),

    p("Incus or OrbStack", "h1"),
    p("The same installer also runs on a Mac with OrbStack; only the host scripts differ. That setup lives in "
      "the `devsys-orbstack` folder with its own README."),
    table([
        ["Concern", "Incus (this runbook)", "OrbStack (`devsys-orbstack`)"],
        ["Host", "Ubuntu server + Incus", "Mac (Apple Silicon) + OrbStack"],
        ["Guest type", "full virtual machine", "OrbStack machine (shared kernel)"],
        ["Golden image", "published image `devsys-base`", "the stopped machine `devsys-base`"],
        ["Per-VM config", "cloud-init user-data", "`newvm.sh` runs `devsys install none`"],
        ["OAuth creds", "mode-600 file on host", "env, mode-600 file, or macOS Keychain"],
        ["Host filesystem", "never mounted into guests", "hidden by `--isolated`"],
        ["Installer", "`devsys-vm.sh` 3.3.0", "the same file"],
    ], [0.22, 0.36, 0.42]),

    p("Phase 1 — Build the golden image (one-time)", "h1"),
    p("1.1 Create the base VM", "h2"),
    p("Incus Web UI → Create instance. Image `ubuntu/24.04/cloud` (the cloud variant — it has cloud-init, which "
      "the clones need), type Virtual machine, name `devsys-base`, ~2 vCPU / 4 GiB / 40 GiB disk. Get a root "
      "shell via the Terminal tab (the Console tab wants a password the cloud image has none of)."),

    p("1.2 Install the toolchain — tools only, no user, no Tailscale", "h2"),
    code("""
GIST=https://gist.githubusercontent.com/secureedge26/574346b153a83b45062460d5433d8a60
curl -fsSL $GIST/raw/devsys-v3.sh | DEVSYS_UNATTENDED=1 bash
"""),
    p("Omitting `DEVSYS_USER` and `DEVSYS_TS_AUTHKEY` installs the pinned tools and nothing VM-specific. Verify: "
      "`exec bash && node --version` → `v26.5.0`, and `devsys status` lists no tool as missing. (Add "
      "`DEVSYS_SHARED_CLAUDE=1` here if you want shared-Claude baked in — see the multi-user section.)"),
    p("Needs installer 3.1.7 or later (this folder has 3.3.0). With 3.1.6 a default install can skip the `node`, `python`, `cloud` and `ai` "
      "groups and still print “Done”: a dpkg prompt about `/etc/zsh/zshenv` swallows the rest of the group list. "
      "This was seen on OrbStack; the code path is the same here. Publish `devsys-incus/devsys-vm.sh` to the "
      "gist as `devsys-v3.sh` before building a base.", "warn"),

    CondPageBreak(170),  # keep the heading, intro and code block on one page
    p("1.3 Generalize + publish", "h2"),
    p("In the base Terminal, strip the per-machine identity (mandatory — or every clone collides), then power off:"),
    code("""
systemctl stop tailscaled 2>/dev/null || true
rm -f /var/lib/tailscale/tailscaled.state
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id && ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs
poweroff
"""),
    p("Then, with the VM Stopped: Web UI → `devsys-base` → Create Image → Alias `devsys-base`. "
      "(`./build-base.sh` on the host does this whole step.)"),

    p("Phase 2 — Tailscale setup (one-time, tailnet-level)", "h1"),
    p("All in the Tailscale admin console, independent of the host — the OrbStack setup uses the same tags and rules."),
    p("2.1 Tags (Definitions → Tags)", "h2"),
    table([
        ["Tag", "Owner"],
        ["`tag:devsys`", "`autogroup:admin, tag:devsys`"],
        ["`tag:soheb`", "`tag:devsys`"],
        ["(one per future dev)", "`tag:devsys`"],
    ], [0.45, 0.55]),
    p("`tag:devsys` must own itself — multi-tag keys require every tag, including tag:devsys, to pass the "
      "ownership check.", "warn"),

    p("2.2 Tailscale SSH rules (Access controls → Tailscale SSH)", "h2"),
    table([
        ["#", "Sources", "Destination", "Users"],
        ["1", "`autogroup:member`", "`autogroup:self`", "`autogroup:nonroot`, `root`"],
        ["2", "`autogroup:admin`", "`tag:devsys`", "`root`"],
        ["3", "`soheb@example.com`", "`tag:soheb`", "`soheb`"],
        ["+1 per dev", "`<dev>@example.com`", "`tag:<dev>`", "`<dev>`"],
    ], [0.14, 0.30, 0.24, 0.32]),
    p("Rule 2 = your admin root reach across the fleet; rules 3+ = each dev into only their own VM. Never use "
      "`tag:devsys` as a source — it would let every VM reach every other VM."),

    CondPageBreak(110),
    p("2.3 OAuth client + host creds", "h2"),
    p("Settings → OAuth clients → scope Auth Keys: Write, Tags = `tag:devsys` + every person-tag. Store on the "
      "host in a mode-600 file (for the `newvm.sh` automation):"),
    code("""
printf 'DEVSYS_TS_CLIENT_ID=%s\\nDEVSYS_TS_CLIENT_SECRET=%s\\n' ID SECRET \\
  > ~/.config/devsys/ts-oauth.env && chmod 600 ~/.config/devsys/ts-oauth.env
"""),

    p("Phase 3 — Clone a developer VM (per VM)", "h1"),
    p("Two paths, same result. Both need a generated auth key — see the rules table below."),
    p("Path A — Web UI (no host shell)", "h2"),
    p("1. Tailscale → Keys → Generate auth key: Reusable off, Ephemeral OFF, Pre-approved on, Tags `tag:devsys` + "
      "`tag:<dev>` → copy the `tskey-auth-…`.", "step"),
    CondPageBreak(140),
    p("2. Web UI → Local images → `devsys-base` → launch → name it, VM, and set Cloud init → User data "
      "(override pencil):", "step"),
    code("""
#cloud-config
hostname: sohebvm
runcmd:
  - >
    DEVSYS_UNATTENDED=1 DEVSYS_USER=soheb
    DEVSYS_TS_HOSTNAME=sohebvm DEVSYS_TS_AUTHKEY=tskey-auth-XXXX
    /usr/local/bin/devsys install none
"""),
    p("3. Create and start — cloud-init sets hostname, creates the dev user, joins Tailscale (seconds; toolchain "
      "already baked).", "step"),

    p("Path B — one command on the host", "h2"),
    code("./newvm.sh sohebvm soheb"),
    p("Mints a dual-tagged, non-ephemeral `tskey-auth-…` from the OAuth client, launches the clone, injects the "
      "cloud-init. No manual key, no secret on the VM. `--login-link` for dev-owned nodes, `--project <dev>` for per-dev Incus projects."),

    p("Auth-key rules — the four things that bite (all avoided by Path B)", "h1"),
    table([
        ["Rule", "Why"],
        ["Use a generated auth key (`tskey-auth-`), never the OAuth client secret (`tskey-client-`).",
         "The client secret is for scripts to MINT keys; pasted as a join key it errors “oauth authkeys require "
         "--advertise-tags” and creates Ephemeral nodes."],
        ["Turn Ephemeral OFF on the key.",
         "Ephemeral nodes are deleted when they go offline (a reboot could remove your dev VM)."],
        ["Tag the key with both `tag:devsys` and `tag:<dev>`.",
         "The VM needs tag:devsys (admin reach) AND tag:<dev> (the dev SSH rule's target). A single-tagged key "
         "means hand-adding the other tag every time."],
        ["Add the per-dev SSH rule (`<dev>@…` → `tag:<dev>`, user `<dev>`).",
         "“not permit you to SSH as user X” = the node matches but no rule grants that Unix user — add this rule."],
    ], [0.45, 0.55]),

    p("Multi-user VM — one Claude login, two GitHub accounts", "h1"),
    p("For a box where one person uses several Unix users (two GitHub identities: `soheb` = account A's repos, "
      "`nv` = account B's). Keep `gh` and `git` per-user (each logs into its own GitHub account) — that's the "
      "account split. Then `DEVSYS_SHARED_CLAUDE=1` lets all the VM's users share one Claude sign-in."),
    table([
        ["Concern", "Scope", "Result"],
        ["Claude (auth, agents, settings, history)", "shared: `CLAUDE_CONFIG_DIR=/opt/devsys/claude`",
         "sign in once, all users use it"],
        ["GitHub auth + git identity", "per-user: `~/.config/gh`, `~/.gitconfig`",
         "claude as soheb → acct A, as nv → acct B"],
    ], [0.30, 0.40, 0.30]),
    p("Enable: bake into the base with `… | DEVSYS_UNATTENDED=1 DEVSYS_SHARED_CLAUDE=1 bash`, or retrofit a live "
      "VM: `sudo devsys update && sudo DEVSYS_SHARED_CLAUDE=1 DEVSYS_USER=<u> devsys install none`. Sign in once "
      "(`claude`); each user reads it after a fresh session."),
    p("New users are automatic: create them with `sudo DEVSYS_UNATTENDED=1 DEVSYS_USER=<name> devsys install "
      "none` — auto-enrolled in the `devs` group, reading the shared login with no sign-in (just a fresh login). "
      "Plain `adduser` does not — you'd `usermod -aG devs <name>` by hand."),
    p("Handled for you: Claude writes credential files mode 0600, which would re-lock other users on each token "
      "refresh; the flag installs a systemd path unit and a 1-minute timer (`devsys-claude-share`) that keep the "
      "shared dir group-readable. Scope is per-VM — never one Claude login across VMs. Skip the flag on "
      "single-developer VMs (pointless there).", "warn"),

    p("Phase 4 — Verify & operate", "h1"),
    table([
        ["Check / task", "Command"],
        ["Admin reach (rule 2)", "`ssh root@sohebvm`"],
        ["Dev login (rule 3)", "`ssh soheb@sohebvm`"],
        ["Isolation (must fail)", "`ssh soheb@`<another dev's VM> → denied"],
        ["Health / versions (in VM)", "`devsys status` · `devsys --list`"],
        ["Add a tool fleet-wide", "edit `MISE_*`/`NPM_*` pins → rebuild base → re-clone"],
        ["Bump the golden image", "`incus start devsys-base` → re-install → `./build-base.sh` again"],
        ["Break-glass into a VM", "`incus exec <vm> -- bash` (on the host)"],
        ["Retire a VM", "delete in Incus + remove from Tailscale Machines"],
    ], [0.36, 0.64]),

    HRFlowable(width="100%", thickness=0.5, color=GRID, spaceBefore=6, spaceAfter=7),
    p("Validated on Incus (beehive): golden image built & published; clones boot with the pinned toolchain, "
      "join Tailscale dual-tagged & non-ephemeral, `ssh root@` (admin) and `ssh <dev>@` (dev) both connect, "
      "per-dev isolation holds. Shared-Claude (3.1.1) verified across root/soheb/nv on one VM with GitHub kept "
      "per-user.", "good"),
    p("Installers 3.2.0 and 3.3.0 (the group-skip fix, the shell setup and Mac locale fix, and the inbound firewall that 3.3.0 adds: Tailscale and loopback only, `DEVSYS_FIREWALL=0` skips it) were tested on OrbStack only — "
      "a full build and clones — and have not been run on Incus.", "warn"),
]

doc = SimpleDocTemplate(str(OUT), pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=54,
                        bottomMargin=50, title=TITLE, author="DevSys")
doc.build(story, onFirstPage=page_frame, onLaterPages=page_frame)
print(f"wrote {OUT}")
