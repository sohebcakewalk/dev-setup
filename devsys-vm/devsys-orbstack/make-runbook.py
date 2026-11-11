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
      "`devsys-vm.sh` (installer 3.2.0) runs inside the guest. You install the pinned toolchain once into a base "
      "machine called `devsys-base`, and every developer VM is a clone of it. Each clone joins Tailscale tagged "
      "`tag:devsys` + `tag:<dev>`; the admin reaches every VM, each developer reaches only their own."),
    table([
        ["Phase", "What", "How often", "Where"],
        ["0", "Prepare the Mac (OrbStack, the scripts)", "once", "the Mac"],
        ["1", "Tailscale tags, SSH rules, OAuth client", "once, plus one tag and rule per developer",
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
        ["`tag:soheb`", "`tag:devsys`"],
        ["(one per future dev)", "`tag:devsys`"],
    ], [0.45, 0.55]),
    p("`tag:devsys` must own itself — a key carrying two tags needs every tag, including `tag:devsys`, to pass "
      "the ownership check. Without it `newvm.sh` stops with “Auth key mint failed”.", "warn"),

    p("1.2 Tailscale SSH rules (Access controls → Tailscale SSH)", "h2"),
    table([
        ["#", "Sources", "Destination", "Users"],
        ["1", "`autogroup:member`", "`autogroup:self`", "`autogroup:nonroot`, `root`"],
        ["2", "`autogroup:admin`", "`tag:devsys`", "`root`"],
        ["3", "`soheb@example.com`", "`tag:soheb`", "`soheb`"],
        ["+1 per dev", "`<dev>@example.com`", "`tag:<dev>`", "`<dev>`"],
    ], [0.14, 0.30, 0.24, 0.32]),
    p("Rule 2 is the admin's root reach across every VM; rules 3 and up let each developer into only their own "
      "VM. Never use `tag:devsys` as a source — it would let every VM reach every other VM."),

    CondPageBreak(150),
    p("1.3 OAuth client, stored on the Mac", "h2"),
    p("Settings → OAuth clients → scope Auth Keys: Write, Tags = `tag:devsys` plus every person-tag. `newvm.sh` "
      "uses it to mint one auth key per VM. Store the client ID and secret in the macOS Keychain:"),
    code("""
security add-generic-password -s ts-oauth -a tailscaleclientid -w '<id>'
security add-generic-password -s ts-oauth -a tailscaleclientsecret -w '<secret>'
"""),
    p("`newvm.sh` looks for the client in this order: the environment (`DEVSYS_TS_CLIENT_ID`, "
      "`DEVSYS_TS_CLIENT_SECRET`), then the mode-600 file `~/.config/devsys/ts-oauth.env` defining the same two "
      "variables, then the Keychain items above."),

    p("Phase 2 — Build the golden base (one-time)", "h1"),
    code("./build-base.sh"),
    p("One command does the whole phase:"),
    p("1. Creates the machine `devsys-base` from `ubuntu:noble`, with `--isolated --isolate-network` so the Mac's "
      "home folder, the other machines' files and machine-to-machine networking are all hidden. Clones inherit "
      "this.", "step"),
    p("2. Copies the `devsys-vm.sh` beside it into the machine and installs every group — no developer user, no "
      "Tailscale login.", "step"),
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
        ["`DEVSYS_BASE_IMAGE=ubuntu:noble`", "distro image for a new base"],
        ["`./build-base.sh devsys-base-next`", "build under a different base name"],
    ], [0.45, 0.55]),

    p("Phase 3 — Clone a developer VM (per developer)", "h1"),
    p("First, in the Tailscale admin console, give the developer their tag and SSH rule (Phase 1.1 and 1.2) and "
      "add the new tag to the OAuth client. Then, on the Mac:"),
    code("./newvm.sh sohebvm soheb"),
    p("The first argument is the VM name (lowercase letters, digits, hyphens), the second the developer's Linux "
      "username. The script:"),
    p("1. Checks that the base exists and is stopped, and that no machine has that name.", "step"),
    p("2. Mints a Tailscale auth key tagged `tag:devsys` + `tag:soheb`: single-use, not ephemeral, "
      "pre-approved, valid for one hour.", "step"),
    p("3. Clones `devsys-base` and starts the clone.", "step"),
    p("4. Inside the clone, creates the user and joins Tailscale with SSH enabled. The key is passed on stdin "
      "and is never written to a file or a command line.", "step"),
    table([
        ["Flag", "Effect"],
        ["`--login-link`", "no admin key: prints a `login.tailscale.com/a/…` link to send to the developer, who "
                           "must already be a tailnet member and becomes the node's owner"],
        ["`--base NAME`", "clone from a different base machine"],
    ], [0.25, 0.75]),
    p("If setup inside the clone fails, the VM is left in place. Inspect it with `orbctl run -m <vm> -u root bash`, "
      "or remove it with `orbctl delete <vm>` and run `newvm.sh` again."),

    p("Phase 4 — Verify and operate", "h1"),
    table([
        ["Check / task", "Command"],
        ["List machines and their state", "`orbctl list`"],
        ["Admin reach (rule 2)", "`ssh root@sohebvm`"],
        ["Dev login (rule 3)", "`ssh soheb@sohebvm`"],
        ["Isolation (must fail)", "`ssh soheb@`<another dev's VM> → denied"],
        ["Health and versions", "`orbctl run -m sohebvm -u root devsys status`"],
        ["Break-glass root shell", "`orbctl run -m sohebvm -u root bash`"],
        ["Change tool versions", "edit the `MISE_*`/`NPM_*` pins in `devsys-vm.sh` → `./build-base.sh` → "
                                 "new clones get them; existing clones are not touched"],
        ["Retire a VM", "`orbctl delete sohebvm`, then remove it from Tailscale → Machines"],
    ], [0.34, 0.66]),
    p("Do not run `devsys update` inside a VM yet. It downloads the published gist copy, which is still 3.1.6, "
      "and replaces 3.2.0 with it. That is safe again once `devsys-vm.sh` is republished to the gist as "
      "`devsys-v3.sh`.", "warn"),

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
        ["`Auth key mint failed`", "`tag:<dev>` is missing, is not owned by `tag:devsys`, is not on the OAuth "
                                   "client, or `tag:devsys` does not own itself (Phase 1.1)"],
        ["“not permit you to SSH as user X”", "the per-developer SSH rule is missing (Phase 1.2)"],
    ], [0.42, 0.58]),

    p("Moving a developer over from the Incus server", "h1"),
    p("An Incus VM cannot be imported into OrbStack. Build the VM fresh with `newvm.sh` under a different "
      "Tailscale name, then copy the home folder through an admin machine that reaches both VMs as root:"),
    code("""
EXCLUDES='--exclude=node_modules --exclude=.venv --exclude=.cache'
ssh root@<old-vm> "tar -C /home/soheb $EXCLUDES -czf - ." \\
  | ssh root@<new-vm> 'tar -C /home/soheb -xzpf -'
"""),
    p("Reinstall `node_modules` and `.venv` in each repo afterwards. Do not copy `/opt/devsys/mise`, "
      "`/var/lib/tailscale` or `/etc/machine-id`. Once the old VM is retired, rename the new one inside the VM "
      "with `tailscale set --hostname=<name>`. This recipe has not been run against the Incus server."),

    HRFlowable(width="100%", thickness=0.5, color=GRID, spaceBefore=6, spaceAfter=7),
    p("Tested on an Apple Silicon Mac (M1 Pro, OrbStack 2.2.4): `build-base.sh` built a base with all 12 groups; "
      "`newvm.sh --login-link` cloned it in 6 seconds with its own hostname and machine-id, the dev user, no "
      "`/mnt/mac`, and every tool at its pinned version.", "good"),
    p("Not yet tested: the Mac Studio itself; key mode (minting a real Tailscale key and joining the tailnet — "
      "that code is carried over from the Incus `newvm.sh`); `DEVSYS_SHARED_CLAUDE=1` on OrbStack; the migration "
      "recipe.", "warn"),
]

doc = SimpleDocTemplate(str(OUT), pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=54,
                        bottomMargin=50, title=TITLE, author="DevSys")
doc.build(story, onFirstPage=page_frame, onLaterPages=page_frame)
print(f"wrote {OUT}")
