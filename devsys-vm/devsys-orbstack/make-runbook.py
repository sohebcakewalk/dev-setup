#!/usr/bin/env python3
"""Build the OrbStack runbook PDF.  Needs reportlab:
    python3 make-runbook.py            # writes devsys-orbstack-runbook.pdf beside this file
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

TITLE = "DevSys VM — OrbStack Golden-Clone Runbook"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("devsys-orbstack-runbook.pdf")

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
    p("Identical, version-pinned Ubuntu dev VMs on a Mac with OrbStack — build one golden base machine, "
      "clone it per developer in seconds, reach each clone over Tailscale.", "subtitle"),
    HRFlowable(width="100%", thickness=1, color=TEAL, spaceAfter=9),

    p("The system: three scripts in the `devsys-orbstack` folder. `build-base.sh` and `newvm.sh` run on the Mac; "
      "`devsys-vm.sh` (installer 3.3.0) runs inside the guest. You install the pinned toolchain once into a base "
      "machine called `devsys-base`, and every developer VM is a clone of it. Each clone joins Tailscale tagged "
      "`tag:devsys` + a tag of its own; the admin reaches every VM, each developer reaches only their own."),
    p("Each VM runs **Ubuntu 26.04 LTS (resolute)**, arm64 on Apple Silicon, on OrbStack's shared Linux kernel."),
    table([
        ["Phase", "What", "How often", "Where"],
        ["0", "Prepare the Mac (OrbStack, the scripts)", "once", "the Mac"],
        ["1", "Tailscale tags, SSH rules, OAuth client", "once, plus one tag and rule per VM",
         "Tailscale admin console"],
        ["2", "Build the golden base", "once, and again to change tool versions", "the Mac"],
        ["3", "Clone a developer VM", "per developer", "the Mac"],
        ["4", "Verify and operate", "ongoing", "the Mac / inside a VM"],
    ], [0.10, 0.36, 0.30, 0.24]),

    p("Phase 0 — Prepare the Mac (one-time)", "h1"),
    p("0.1 Install OrbStack", "h2"),
    p("Install OrbStack (`brew install orbstack`, or the download from orbstack.dev) and open it once so that "
      "`orbctl` is on the PATH. Check both tools the scripts need:"),
    code("""
orbctl version
jq --version
"""),
    p("The VMs run only while OrbStack is running. Set OrbStack to start at login and keep the Mac from sleeping, "
      "or developers lose their VMs when it does."),
    p("0.2 Get the scripts", "h2"),
    code("""
git clone https://github.com/sohebcakewalk/dev-setup.git
cd dev-setup/devsys-vm/devsys-orbstack
"""),
    p("0.3 Tailscale on the Mac (optional)", "h2"),
    p("Install the Tailscale app and sign in as a tailnet admin if you want to `ssh` into the VMs from this Mac. "
      "Without it you can still get a root shell in any VM with `orbctl run`."),

    p("Phase 1 — Tailscale setup (one-time, tailnet-level)", "h1"),
    p("All in the Tailscale admin console. The tags and rules are the same ones the Incus setup uses."),
    CondPageBreak(140),  # keep the heading with its table
    p("1.1 Tags (Definitions → Tags)", "h2"),
    table([
        ["Tag", "Owner"],
        ["`tag:devsys`", "`autogroup:admin, tag:devsys`"],
        ["`tag:beehivekk`", "`tag:devsys`"],
        ["(one per further VM)", "`tag:devsys`"],
    ], [0.45, 0.55]),
    p("`tag:devsys` must own itself — a key carrying two tags needs every tag, including `tag:devsys`, to pass "
      "the ownership check. Without it `newvm.sh` stops with “Auth key mint failed”.", "warn"),

    p("1.2 Tailscale SSH rules (Access controls → Tailscale SSH)", "h2"),
    table([
        ["#", "Sources", "Destination", "Users"],
        ["1", "`autogroup:member`", "`autogroup:self`", "`autogroup:nonroot`, `root`"],
        ["2", "`autogroup:admin`", "`tag:devsys`", "`root`"],
        ["3", "`bh@github`", "`tag:beehivekk`", "`autogroup:nonroot`"],
        ["+1 per VM", "`<login>@github`", "`tag:<vm>`", "`autogroup:nonroot`"],
    ], [0.14, 0.30, 0.24, 0.32]),
    p("Rule 2 is the admin's root reach across every VM; rules 3 and up let each developer into only their own "
      "VM. Never use `tag:devsys` as a source — it would let every VM reach every other VM."),
    p("Sources is the developer's Tailscale login as the Users page shows it, for example `name@github` for "
      "someone who signed up with GitHub. `autogroup:nonroot` lets them log in as any Linux user on their VM "
      "except `root`, so usernames can be chosen freely; list names instead (`bh`, `admin`) to restrict it."),

    CondPageBreak(150),
    p("1.3 OAuth client, stored on the Mac", "h2"),
    p("The OAuth client is what lets `newvm.sh` create a fresh Tailscale auth key for each VM, so nobody has to "
      "generate and paste keys by hand. Create it once: Settings → Trust credentials → Credential → OAuth, scope "
      "Auth Keys: Write, tag `tag:devsys`."),
    p("That one tag is enough for every developer. A client may mint a key for any tag its own tag owns, and "
      "`tag:devsys` owns itself and each VM tag (1.1). This follows Tailscale's documentation and has not "
      "been run here; if minting is refused for a new developer, add their tag to the client as well."),
    p("Store the client ID and secret in the macOS Keychain:"),
    code("""
security add-generic-password -s ts-oauth -a tailscaleclientid -w '<id>'
security add-generic-password -s ts-oauth -a tailscaleclientsecret -w '<secret>'
"""),
    p("`newvm.sh` looks for the client in this order: the environment (`DEVSYS_TS_CLIENT_ID`, "
      "`DEVSYS_TS_CLIENT_SECRET`), then the mode-600 file `~/.config/devsys/ts-oauth.env` defining the same two "
      "variables, then the Keychain items above."),
    p("The secret is long-lived: anyone who can read it can mint keys for these tags. Keep it only in the "
      "Keychain or the mode-600 file, and revoke the client in Tailscale if the Mac is ever compromised.", "warn"),

    p("Phase 2 — Build the golden base (one-time)", "h1"),
    code("./build-base.sh"),
    p("One command does the whole phase:"),
    p("1. Creates the machine `devsys-base` from `ubuntu:resolute` (Ubuntu 26.04 LTS), with `--isolated --isolate-network` so the Mac's "
      "home folder and the other machines' files are hidden. Clones inherit this.", "step"),
    p("2. Copies the `devsys-vm.sh` beside it into the machine and installs every group, including the inbound "
      "firewall — no developer user, no Tailscale login.", "step"),
    p("3. Clears the per-machine identity (machine-id, Tailscale state, SSH host keys).", "step"),
    p("4. Stops the machine.", "step"),
    p("On an M1 Pro this took about 3 minutes and 3.4 GB. Check the result with `orbctl list`: `devsys-base` "
      "must show as stopped."),
    p("The stopped base is the image. Do not start it by hand: a running base regenerates the identity that "
      "clones must not share, and `newvm.sh` refuses to clone it. To change it, re-run `./build-base.sh`.", "warn"),
    table([
        ["Option (environment variable)", "Effect"],
        ["`DEVSYS_GROUPS=\"node python ai\"`", "install only these groups into the base"],
        ["`DEVSYS_SHARED_CLAUDE=1`", "bake in the shared-Claude setup (several Unix users, one Claude login)"],
        ["`DEVSYS_BASE_IMAGE=ubuntu:noble`", "use another image for a new base, here Ubuntu 24.04 LTS (default: `ubuntu:resolute`)"],
        ["`./build-base.sh devsys-base-next`", "build under a different base name"],
    ], [0.45, 0.55]),

    p("Phase 3 — Clone a developer VM (per developer)", "h1"),
    p("3.1 Checklist for each developer", "h2"),
    p("1. Tailscale → Tags: add `tag:<vm>`, owned by `tag:devsys` (1.1).", "step"),
    p("2. Tailscale → SSH rules: add the developer's Tailscale login → `tag:<vm>` → `autogroup:nonroot` "
      "(1.2).", "step"),
    p("3. On the Mac, in the `devsys-orbstack` folder:", "step"),
    code("./newvm.sh beehivekk bh --tag beehivekk"),
    p("The first argument is the VM name (lowercase letters, digits, hyphens). The second is the first Linux "
      "username to create; it can be anything (`bh`, `admin`, `nv`). `--tag` names the Tailscale tag, here after "
      "the VM, so the SSH rule points at this one VM whatever its usernames are. Without `--tag` the tag is "
      "named after the username (`tag:bh`), which only works while every VM has a different username."),
    p("Repeat the three steps for every developer; nothing on the Mac or in the OAuth client changes between "
      "them. A developer who should own their VM under their own Tailscale account can join with a login link "
      "instead (3.4)."),

    p("3.2 What `newvm.sh` does", "h2"),
    p("1. **Checks first.** The base must exist and be stopped, and no machine may already have that name. A "
      "failed check stops the script before anything is asked of Tailscale.", "step"),
    p("2. **Reads the OAuth client** from the environment, the mode-600 file, or the Keychain (1.3).", "step"),
    p("3. **Gets a temporary access token** from Tailscale with that client.", "step"),
    p("4. **Mints an auth key** tagged `tag:devsys` + `tag:beehivekk`: single-use, not ephemeral, pre-approved, "
      "valid for one hour.", "step"),
    p("5. **Clones** `devsys-base` and starts the clone.", "step"),
    p("6. **Sets up the clone**: clears any Tailscale state, creates the user, and joins the tailnet with "
      "`tailscale up --ssh --accept-dns=false --accept-routes=true`.", "step"),
    p("The key never appears on screen, in a file, or in a command line; it is handed to the clone on stdin. The "
      "second tag is the one given with `--tag`, or the username when `--tag` is left out."),
    table([
        ["Key setting", "Why it matters"],
        ["Not ephemeral", "an ephemeral VM is removed from the tailnet whenever it goes offline"],
        ["Both tags", "`tag:devsys` gives the admin root reach; `tag:<vm>` is what the developer's SSH rule "
                      "points at"],
        ["Pre-approved", "the VM joins without waiting for device approval"],
        ["Single-use, one hour", "a leaked key cannot add a second machine"],
    ], [0.30, 0.70]),
    p("`--accept-dns=false` keeps the VM on its own DNS, so Tailscale's MagicDNS cannot break ordinary lookups "
      "such as npm. You still reach the VM by name from your Mac. To let one VM look up other tailnet machines "
      "by short name, run `tailscale set --accept-dns=true` inside it."),
    p("To clone from a different base machine, add `--base NAME`. If setup inside the clone fails, the VM is "
      "left in place: inspect it with `orbctl run -m <vm> -u root bash`, or remove it with `orbctl delete <vm>` "
      "and run `newvm.sh` again."),

    p("3.3 A second user on the same VM", "h2"),
    p("To add another Linux user to an existing VM, for example `admin` beside `bh`:"),
    code("""
orbctl run -m beehivekk -u root \\
  env DEVSYS_UNATTENDED=1 DEVSYS_USER=admin devsys install none
"""),
    p("The new user gets the same shell setup, `~/work` folder and tools. Tailscale is not touched. A rule whose "
      "users are `autogroup:nonroot` (1.2) already lets the developer log in as the new user. If your rule lists "
      "usernames instead, add this one to it."),
    p("Every user the script creates has passwordless `sudo`, so `admin` has no more rights than `bh`. To make "
      "one of them an ordinary user, remove its sudo access:"),
    code("""
orbctl run -m beehivekk -u root \\
  bash -c 'rm -f /etc/sudoers.d/90-devsys-bh; gpasswd -d bh sudo'
"""),
    p("That user can then no longer run the `devsys` subcommands that need root (`mise`, `npm`, `serve`, "
      "`fix-dns`). Claude, GitHub and git logins are separate for each user."),

    p("3.4 Alternative: the developer joins with a login link", "h2"),
    p("Use this when a developer should own their VM under their own Tailscale account. It needs no OAuth "
      "client, no tag and no per-developer SSH rule; the developer only has to be a member of the tailnet "
      "already (Users → Invite)."),
    code("./newvm.sh beehivekk bh --login-link"),
    p("The script clones the VM and creates the user as before, but mints no key. It prints a "
      "`login.tailscale.com/a/…` link. Send it to the developer; when they open it and sign in, the VM joins "
      "the tailnet as their device. If no link is printed, fetch one with "
      "`orbctl run -m beehivekk -u root devsys ts-login`."),
    table([
        ["", "Automatic key (3.1)", "Login link (3.4)"],
        ["VM owner in Tailscale", "the tailnet (tagged `tag:devsys` + `tag:<vm>`)", "the developer"],
        ["Tailscale setup per developer", "one tag and one SSH rule", "none, just the invite"],
        ["Developer's SSH access", "their own rule (rule 3)", "rule 1: members reach their own devices"],
        ["Admin `ssh root@<vm>`", "yes (rule 2)", "no: the VM has no `tag:devsys`; use `orbctl run` from the Mac"],
        ["Who finishes the join", "the script", "the developer, in a browser"],
        ["Key expiry", "off for tagged devices", "the tailnet's normal expiry applies; the developer "
                                                 "re-authenticates when it lapses"],
    ], [0.26, 0.37, 0.37]),
    p("The two can be mixed: some VMs tagged, some developer-owned. Creating the VM with this flag was tested "
      "on OrbStack; the browser sign-in that completes the join was not recorded as tested.", "warn"),

    p("Phase 4 — Verify and operate", "h1"),
    table([
        ["Check / task", "Command"],
        ["List machines and their state", "`orbctl list`"],
        ["Admin reach (rule 2)", "`ssh root@beehivekk`"],
        ["Dev login (rule 3)", "`ssh bh@beehivekk`"],
        ["Isolation (must fail)", "`ssh bh@`<another dev's VM> → denied"],
        ["Firewall is on", "`orbctl run -m beehivekk -u root systemctl is-active devsys-firewall` → `active`"],
        ["Health and versions", "`orbctl run -m beehivekk -u root devsys status`"],
        ["Break-glass root shell", "`orbctl run -m beehivekk -u root bash`"],
        ["Change tool versions", "edit the `MISE_*`/`NPM_*` pins in `devsys-vm.sh` → `./build-base.sh` → "
                                 "new clones get them; existing clones are not touched"],
        ["Retire a VM", "`orbctl delete beehivekk`, then remove it from Tailscale → Machines"],
    ], [0.34, 0.66]),
    p("Do not run `devsys update` inside a VM yet. It downloads the published gist copy, which is still 3.1.6, "
      "and replaces 3.3.0 with it. That is safe again once `devsys-vm.sh` is republished to the gist as "
      "`devsys-v3.sh`.", "warn"),

    CondPageBreak(300),  # keep the heading with its table
    p("What a developer can and cannot reach", "h1"),
    p("Checked on OrbStack 2.2.4 with a base and two clones, as root inside a clone."),
    table([
        ["From inside a VM", "Result", "What enforces it"],
        ["The Mac's files (`/mnt/mac`, `/Users`, `/Volumes`)", "not present", "`--isolated`"],
        ["Other VMs' files (`/mnt/machines`)", "not present", "`--isolated`"],
        ["Mac commands, the Mac's SSH agent, the Docker socket", "not available", "`--isolated`"],
        ["A port on another VM", "blocked", "the inbound firewall in each VM"],
        ["Services on the Mac, via the Mac's LAN address", "**reachable**", "nothing (see below)"],
        ["The internet", "reachable", "intended"],
    ], [0.46, 0.20, 0.34]),
    p("`--isolate-network` alone does not separate the VMs: with it set, one clone still connected to a port on "
      "another. So installer 3.3.0 gives every VM its own firewall. It drops new incoming connections except "
      "over Tailscale and loopback, leaves outgoing traffic alone, is baked into the base, starts at boot, and "
      "is reported by `devsys status`. The rules are in `/etc/devsys/firewall.nft`."),
    p("A dev server is therefore reachable over Tailscale (`devsys serve <port>`, or the VM's tailnet address) "
      "but not from other VMs, and not from the Mac at `<vm>.orb.local`. `DEVSYS_FIREWALL=0 ./build-base.sh` "
      "builds a base without the firewall."),
    p("What is left open:", "h2"),
    p("• **The Mac's own network services.** A VM can connect to anything the Mac offers on its LAN address "
      "(Remote Login, Screen Sharing, File Sharing). Turn off the ones you do not need in System Settings → "
      "General → Sharing.", "step"),
    p("• **Root inside the VM.** Every developer has passwordless `sudo` and can stop their own firewall. That "
      "exposes only their own VM. Two users on one VM can read each other's files.", "step"),
    p("• **The shared kernel.** OrbStack says isolated machines are not a full security boundary. Use the Incus "
      "setup when developers must be strongly separated.", "step"),
    p("• **Tailscale's network policy.** The SSH rules decide who can log in; whether one VM can reach another's "
      "ports over the tailnet is decided by the tailnet's access rules, which allow everything by default.",
      "step"),

    CondPageBreak(280),  # keep the heading with its table
    p("When something stops", "h1"),
    table([
        ["Message", "Fix"],
        ["`orbctl not found`", "install OrbStack and open it once (Phase 0.1)"],
        ["`No base machine 'devsys-base'`", "run `./build-base.sh`"],
        ["`Base 'devsys-base' is running, not stopped`", "re-run `./build-base.sh`; do not stop it by hand, its "
                                                         "identity has to be cleared again"],
        ["`A machine named '…' already exists`", "pick another name, or `orbctl delete` the old one"],
        ["`No Tailscale OAuth client`", "store the client ID and secret (Phase 1.3)"],
        ["`OAuth token exchange failed`", "the stored ID or secret is wrong or revoked"],
        ["`Auth key mint failed`", "the VM tag is missing or not owned by `tag:devsys`, or `tag:devsys` "
                                   "does not own itself (Phase 1.1). If both are right, add the VM tag to the "
                                   "OAuth client (1.3)"],
        ["“not permit you to SSH as user X”", "no SSH rule lists that username for this VM's tag (Phase 1.2, 3.3)"],
    ], [0.42, 0.58]),

    p("Moving a developer over from the Incus server", "h1"),
    p("An Incus VM cannot be imported into OrbStack. Build the VM fresh with `newvm.sh` under a different "
      "Tailscale name, then copy the home folder through an admin machine that reaches both VMs as root:"),
    code("""
EXCLUDES='--exclude=node_modules --exclude=.venv --exclude=.cache'
ssh root@<old-vm> "tar -C /home/bh $EXCLUDES -czf - ." \\
  | ssh root@<new-vm> 'tar -C /home/bh -xzpf -'
"""),
    p("Reinstall `node_modules` and `.venv` in each repo afterwards. Do not copy `/opt/devsys/mise`, "
      "`/var/lib/tailscale` or `/etc/machine-id`. Once the old VM is retired, rename the new one inside the VM "
      "with `tailscale set --hostname=<name>`. This recipe has not been run against the Incus server."),

    HRFlowable(width="100%", thickness=0.5, color=GRID, spaceBefore=6, spaceAfter=7),
    p("Tested on an Apple Silicon Mac (M1 Pro, OrbStack 2.2.4): `build-base.sh` built a base with all 12 groups; "
      "`newvm.sh`, run without a Tailscale key, cloned it in 6 seconds with its own hostname and machine-id, the "
      "dev user, no `/mnt/mac`, and every tool at its pinned version. With installer 3.3.0, a connection from one "
      "clone to a port on the other was refused in both directions, went through when one firewall was stopped, "
      "and was refused again after a restart. The same build and clone checks passed on Ubuntu 26.04 LTS, the default image.", "good"),
    p("Not yet tested: the Mac Studio itself; steps 2 to 4 and the Tailscale join in 3.2 (minting a real key and "
      "joining the tailnet — that code is carried over from the Incus `newvm.sh`); the firewall on a VM that has "
      "joined a tailnet (Tailscale SSH and `devsys serve` through it); the second-user commands in "
      "3.3 on OrbStack; `DEVSYS_SHARED_CLAUDE=1` on OrbStack; the migration recipe. Try the first VM end to end "
      "before creating the rest.", "warn"),
]

doc = SimpleDocTemplate(str(OUT), pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=54,
                        bottomMargin=50, title=TITLE, author="DevSys")
doc.build(story, onFirstPage=page_frame, onLaterPages=page_frame)
print(f"wrote {OUT}")
