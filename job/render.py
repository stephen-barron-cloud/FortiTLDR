#!/usr/bin/env python3
"""Render a FortiTLDR report (light Markdown) as email-safe HTML on stdout.

Usage: render.py report.md > report.html

Understands only what prompt.md asks Claude to write:
  # Heading / ## Subheading / ### Group heading
  - bullet            (an indented line right after a bullet continues it)
  [URGENT] [HIGH] [MEDIUM] [LOW] at the start of a bullet or paragraph
  **bold**, bare URLs (made clickable), blank lines between paragraphs
  "-- " on its own line starts the footer
The status banner follows the tag on the TL;DR (the first section), not the most
severe tag anywhere in the email, so lifecycle or news items never raise it.
Everything is HTML-escaped first, so nothing in the report can inject markup.
All styles are inline because many email clients drop <style> blocks."""
import datetime, html, re, sys

FONT = ("-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', "
        "Arial, sans-serif")
# Dark theme: soft off-white text on dark gray (not pure black/white, which glares).
PAGE, CARD, TEXT, MUTED, RULE, LINK = ("#16181c", "#202329", "#dde1e6", "#9aa3ad",
                                       "#363b44", "#8ab4f8")
# level: (label, text/border color, tinted background)
LEVELS = {
    "URGENT": ("Urgent", "#ff8a80", "#3b2224"),
    "HIGH":   ("High",   "#ffb067", "#3a2a1b"),
    "MEDIUM": ("Medium", "#ecc75a", "#353019"),
    "LOW":    ("Low",    "#6fcf86", "#1c3123"),
}
ORDER = ["URGENT", "HIGH", "MEDIUM", "LOW"]
TAG = re.compile(r"^\[(URGENT|HIGH|MEDIUM|LOW)\]\s*")
URL = re.compile(r"(https?://[^\s<>\"')\]]+[^\s<>\"').,;:\]])")


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    return URL.sub(lambda m: f'<a href="{m.group(1)}" style="color:{LINK};'
                             f'text-decoration:underline;word-break:break-all;">{m.group(1)}</a>', t)


def badge(level):
    label, fg, bg = LEVELS[level]
    return (f'<span style="display:inline-block;padding:1px 7px;margin-right:6px;'
            f'border-radius:10px;font-size:11px;font-weight:700;letter-spacing:.3px;'
            f'text-transform:uppercase;color:{fg};background:{bg};border:1px solid {fg};">'
            f'{label}</span>')


def tagged(text):
    """Return (level or None, html) for a line that may start with a tag."""
    m = TAG.match(text)
    if not m:
        return None, inline(text)
    return m.group(1), badge(m.group(1)) + inline(text[m.end():])


def render(src):
    lines = src.replace("\r\n", "\n").split("\n")
    body, footer, levels = [], [], set()
    in_list, para, item = False, [], None
    in_footer = False
    h1_count, banner = 0, None   # banner = first tag seen in section 1 (TL;DR)

    def flush_item():
        nonlocal item
        if item is not None:
            level, parts = item
            fg, bg = (LEVELS[level][1], LEVELS[level][2]) if level else (RULE, "transparent")
            body.append(f'<li style="margin:0 0 6px 0;padding:5px 10px;list-style:none;'
                        f'border-left:4px solid {fg};background:{bg};border-radius:3px;">'
                        + "<br>".join(parts) + "</li>")
            item = None

    def close_list():
        nonlocal in_list
        flush_item()
        if in_list:
            body.append("</ul>")
            in_list = False

    def flush_para():
        nonlocal para
        if para:
            level, h = tagged(" ".join(para))
            if level:
                levels.add(level)
                note_banner(level)
                fg, bg = LEVELS[level][1], LEVELS[level][2]
                body.append(f'<p style="margin:0 0 10px 0;padding:6px 10px;border-left:4px solid '
                            f'{fg};background:{bg};border-radius:3px;">{h}</p>')
            else:
                body.append(f'<p style="margin:0 0 10px 0;">{h}</p>')
            para = []

    def note_banner(level):
        nonlocal banner
        if h1_count <= 1 and banner is None:
            banner = level

    for raw in lines:
        line = raw.rstrip()
        if in_footer:
            footer.append(line)
            continue
        if line == "--" or line == "-- ":
            flush_para(); close_list(); in_footer = True
            continue
        if not line.strip():
            flush_para(); flush_item()
            continue
        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            flush_para(); close_list()
            n, t = len(m.group(1)), inline(m.group(2))
            if n == 1:
                h1_count += 1
            if n == 1:
                body.append(f'<h2 style="margin:26px 0 10px 0;padding-bottom:6px;font-size:19px;'
                            f'font-weight:700;color:{TEXT};border-bottom:2px solid {RULE};">{t}</h2>')
            elif n == 2:
                body.append(f'<h3 style="margin:18px 0 8px 0;font-size:15px;font-weight:700;'
                            f'color:{TEXT};">{t}</h3>')
            else:
                body.append(f'<h4 style="margin:14px 0 6px 0;font-size:13px;font-weight:700;'
                            f'color:{MUTED};text-transform:uppercase;letter-spacing:.4px;">{t}</h4>')
            continue
        m = re.match(r"^\s*[-*]\s+(.*)$", line)
        if m and not (item is not None and raw.startswith("  ") and not raw.lstrip().startswith(("- ", "* "))):
            flush_para(); flush_item()
            if not in_list:
                body.append('<ul style="margin:0 0 12px 0;padding:0;">')
                in_list = True
            level, h = tagged(m.group(1).strip())
            if level:
                levels.add(level)
                note_banner(level)
            item = (level, [h])
            continue
        if item is not None and (raw.startswith("  ") or line.startswith("More info:")):
            item[1].append(f'<span style="font-size:13px;color:{MUTED};">{inline(line.strip())}</span>')
            continue
        close_list()
        para.append(line.strip())
    flush_para(); close_list()

    top = banner
    if top:
        label, fg, bg = LEVELS[top]
        status = {"URGENT": "New or escalated major security event",
                  "HIGH": "Security action needed",
                  "MEDIUM": "Nothing urgent; items to plan for",
                  "LOW": "No critical security events today"}[top]
    else:
        label, fg, bg, status = "Info", MUTED, PAGE, "Informational only"
    legend = " ".join(f'<span style="white-space:nowrap;margin-right:10px;">'
                      f'<span style="display:inline-block;width:9px;height:9px;border-radius:2px;'
                      f'background:{LEVELS[l][1]};margin-right:4px;"></span>{LEVELS[l][0]}</span>'
                      for l in ORDER)
    foot = "<br>".join(inline(l) for l in footer if l.strip())
    today = datetime.date.today().strftime("%A, %B %-d, %Y")

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark">
<title>FortiTLDR</title></head>
<body style="margin:0;padding:0;background:{PAGE};color:{TEXT};">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="{PAGE}" style="background:{PAGE};">
<tr><td align="center" style="padding:20px 12px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="{CARD}" style="max-width:720px;background:{CARD};border:1px solid {RULE};border-radius:8px;">
<tr><td style="padding:20px 24px 14px 24px;border-bottom:1px solid {RULE};font-family:{FONT};">
<div style="font-size:22px;font-weight:700;color:{TEXT};">FortiTLDR</div>
<div style="font-size:13px;color:{MUTED};margin-top:2px;">Daily Fortinet briefing &middot; {today}</div>
<div style="margin-top:12px;padding:8px 12px;border-radius:6px;background:{bg};border-left:4px solid {fg};font-size:14px;color:{TEXT};">
<strong style="color:{fg};">{label}:</strong> {status}</div>
<div style="margin-top:8px;font-size:12px;color:{MUTED};">{legend}</div>
</td></tr>
<tr><td style="padding:6px 24px 20px 24px;font-family:{FONT};font-size:15px;line-height:1.6;color:{TEXT};">
{chr(10).join(body)}
</td></tr>
<tr><td style="padding:14px 24px;border-top:1px solid {RULE};font-family:{FONT};font-size:12px;line-height:1.5;color:{MUTED};">
{foot}
</td></tr>
</table>
</td></tr></table>
</body></html>
"""


if __name__ == "__main__":
    sys.stdout.write(render(open(sys.argv[1], encoding="utf-8").read()))
