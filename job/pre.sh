#!/usr/bin/env python3
"""Check every URL in ./feeds for new/updated items.
RSS/Atom feeds: each item is tracked. Other pages: the visible text is tracked
and a diff is produced when it changes.
exit 3 = nothing changed; exit 0 = changes written to new-items.md, subject, tools.
Touch 'force-latest' in this folder to treat the newest item of the first feed
as new on the next run (for testing the email pipeline).
Product lifecycle items (End of Order / End of Support dates) whose milestones fall
within the next N days (file 'lifecycle-days', default 90; 0 = off) are listed every
run, so the briefing is sent daily while anything is upcoming."""
import datetime, difflib, hashlib, html, json, os, re, sys, urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

STATE, PENDING, SNAP = "seen.json", "seen.pending.json", "snapshots"
UA = {"User-Agent": "FortiTLDR/1.0 (+feed watcher)"}

def sha(s): return hashlib.sha256(s.encode()).hexdigest()
def local(tag): return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""
def text(el, name):
    for c in el:
        if local(c.tag) == name:
            return (c.text or "").strip()
    return ""

def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return r.read()

def page_text(raw):
    p = raw.decode("utf-8", "replace")
    m = re.search(r"(?is)<title[^>]*>(.*?)</title>", p)
    title = html.unescape(m.group(1).strip()) if m else ""
    p = re.sub(r"(?is)<(script|style|noscript|svg)[^>]*>.*?</\1>", " ", p)
    p = re.sub(r"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr|section|article)>", "\n", p)
    p = html.unescape(re.sub(r"(?s)<[^>]+>", " ", p))
    lines = [re.sub(r"[ \t\r\f\v]+", " ", l).strip() for l in p.split("\n")]
    return title, "\n".join(l for l in lines if l)

def parse(url, raw):
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        root = None
    if root is not None and local(root.tag) in ("rss", "RDF", "feed"):
        src = text(root, "title")
        for el in root.iter():
            if local(el.tag) == "channel":
                src = text(el, "title"); break
        items = []
        for el in root.iter():
            kind = local(el.tag)
            if kind == "item":
                title, link, desc = text(el, "title"), text(el, "link"), text(el, "description")
                link = text(el, "origLink") or link   # FeedBurner: skip the tracking redirect
                # No <guid>: some feeds (e.g. Fortinet firmware) reuse one link for every
                # item, so combine link + title to keep items distinct.
                guid = text(el, "guid") or (link + "|" + title if link else title)
                date = text(el, "pubDate") or text(el, "date")
            elif kind == "entry":
                title = text(el, "title")
                link = next((c.get("href", "") for c in el if local(c.tag) == "link"
                             and c.get("rel", "alternate") == "alternate"), "")
                desc = text(el, "summary") or text(el, "content")
                guid = text(el, "id") or link or title
                date = text(el, "updated") or text(el, "published")
            else:
                continue
            items.append(dict(guid=guid, title=title, link=link, date=date, desc=desc,
                              src=src or url, hash=sha(title + "\n" + desc)))
        return items
    title, body = page_text(raw)
    return [dict(guid="page:" + url, title=title or url, link=url, date="", desc="",
                 src=url, hash=sha(body), body=body)]

feeds = [l.strip() for l in open("feeds") if l.strip() and not l.strip().startswith("#")]
try:
    seen = json.load(open(STATE))
except FileNotFoundError:
    seen = {}
known = set(seen.get("__feeds__", []))
force = os.path.exists("force-latest")
if force:
    os.remove("force-latest")
os.makedirs(SNAP, exist_ok=True)

merged, new, upd, ok, errors = dict(seen), [], [], [], []
parsed = []
for url in feeds:
    try:
        parsed.append((url, parse(url, fetch(url))))
    except Exception as e:
        errors.append(f"{url}: {e}"); print(f"WARN {url}: {e}", file=sys.stderr)

# Some IDs are not unique: Fortinet's lifecycle feeds repeat the same ID for different
# rows, and some IDs appear in two feeds (e.g. Hardware + Services, OT IPS + OT App
# Control). Colliding items get a feed+content-based ID so they don't overwrite each
# other in seen.json and get reported as UPDATED on every run.
counts = {}
for url, items in parsed:
    for i in items:
        counts[i["guid"]] = counts.get(i["guid"], 0) + 1
for url, items in parsed:
    for i in items:
        if counts[i["guid"]] > 1:
            i["base"] = i["guid"]
            i["guid"] = i["guid"] + "#" + sha(url + "\n" + i["hash"])[:16]

for url, items in parsed:
    ok.append(url)
    snap = os.path.join(SNAP, sha(url)[:16] + ".txt")
    for i in items:
        if "body" not in i:
            continue
        old_body = open(snap).read() if os.path.exists(snap) else None
        if url not in known or old_body is None:
            open(snap, "w").write(i["body"])
        elif seen.get(i["guid"]) != i["hash"]:
            diff = list(difflib.unified_diff(old_body.splitlines(), i["body"].splitlines(),
                                             "before", "after", lineterm="", n=1))
            i["desc"] = "Text diff (truncated):\n```\n" + "\n".join(diff[:150]) + "\n```"
            open(snap + ".pending", "w").write(i["body"])
    if url not in known:
        print(f"New source - saved {len(items)} item(s) as baseline: {url}")
        merged.update({i["guid"]: i["hash"] for i in items})
        if not (force and url == feeds[0] and items):
            continue
        seen = {**seen, **{i["guid"]: i["hash"] for i in items}}
    if force and url == feeds[0] and items:
        seen = {k: v for k, v in seen.items() if k != items[0]["guid"]}
    # One-time upgrade: rows stored under an old colliding ID are already known,
    # so record them silently under their new ID and drop the old one.
    for i in items:
        if "base" in i and i["guid"] not in seen and i["base"] in seen:
            seen[i["guid"]] = i["hash"]
            merged.pop(i["base"], None)
    for i in items:
        old = seen.get(i["guid"])
        if old is None:
            new.append(i)
        elif old != i["hash"]:
            upd.append(i)
        merged[i["guid"]] = i["hash"]

if not ok:
    print("Every URL failed to load:\n" + "\n".join(errors), file=sys.stderr); sys.exit(1)

# Drop items whose TITLE matches a line in ./ignore (they are still marked as seen).
# "category:<text>" lines match a lifecycle item's Category instead of its title.
def category(i):
    m = re.search(r"Category:\s*([^,<]+)", i["desc"])
    return m.group(1).strip() if m else ""

patterns = []   # (field, compiled regex)
if os.path.exists("ignore"):
    for line in open("ignore"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        field = "title"
        if line.lower().startswith("category:"):
            field, line = "category", line[9:].strip()
        if line.lower().startswith("re:"):
            try:
                patterns.append((field, re.compile(line[3:].strip(), re.I)))
            except re.error as e:
                print(f"WARN bad regex in ignore file, skipped: {line} ({e})", file=sys.stderr)
        elif field == "category":
            patterns.append((field, re.compile(r"^" + re.escape(line) + r"$", re.I)))
        else:
            patterns.append((field, re.compile(re.escape(line), re.I)))
is_ignored = lambda i: any(p.search(i["title"] if f == "title" else category(i))
                           for f, p in patterns)
skipped = [i for i in new + upd if is_ignored(i)]
new = [i for i in new if not is_ignored(i)]
upd = [i for i in upd if not is_ignored(i)]
for i in skipped:
    print(f"Ignored: {i['title']}")
merged["__feeds__"] = sorted(known | set(ok))
json.dump(merged, open(PENDING, "w"), indent=1)

# ---- Upcoming product lifecycle milestones ----
MILESTONE = re.compile(r"(End of Order|End of Engineering Support|Last Service Extension|"
                       r"End of Support):\s*(\d{4}-\d{2}-\d{2})")
def milestones(i):
    out = []
    for name, d in MILESTONE.findall(i["desc"]):
        try:
            out.append((name, datetime.date.fromisoformat(d)))
        except ValueError:
            pass
    return out
is_lifecycle = lambda i: bool(milestones(i))
def lc_group(url):
    name = url.rstrip("/").rsplit("/", 1)[-1].lower()
    return ("Hardware & VM" if "hardware" in name else "Software" if "software" in name
            else "Services" if "services" in name else url)

try:
    days = int(open("lifecycle-days").read().strip())
except (FileNotFoundError, ValueError):
    days = 90
today = datetime.date.today()
horizon = today + datetime.timedelta(days=days)
upcoming, seen_rows = [], set()   # (soonest date, group, line)
for url, items in parsed:
    for i in items:
        ms = milestones(i)
        soon = [(n, d) for n, d in ms if today <= d <= horizon]
        if days <= 0 or not soon or is_ignored(i):
            continue
        row = (i["title"], tuple(ms))
        if row in seen_rows:          # identical row listed twice in the feeds
            continue
        seen_rows.add(row)
        first = min(d for _, d in soon)
        dates = "; ".join(f"{n} {d.isoformat()}" + (f" (in {(d - today).days} days)"
                          if today <= d <= horizon else "") for n, d in ms)
        cat = category(i)
        upcoming.append((first, lc_group(url),
                         f"- {i['title']}" + (f" [{cat}]" if cat else "") + f": {dates}"))
upcoming.sort()

if not new and not upd and not upcoming:
    os.replace(PENDING, STATE)
    print(f"No changes across {len(ok)} source(s) and no lifecycle milestones in the next {days} days.")
    sys.exit(3)

def item_block(label, i):
    return (f"## [{label}] {i['title']}\n- Source: {i['src']}\n- Link: {i['link']}\n"
            f"- Published: {i['date'] or 'n/a'}\n- Summary: {i['desc'] or 'n/a'}\n")

lc_new = [i for i in new if is_lifecycle(i)]
lc_upd = [i for i in upd if is_lifecycle(i)]
other_new = [i for i in new if not is_lifecycle(i)]
other_upd = [i for i in upd if not is_lifecycle(i)]

blocks = [f"# Today is {today.isoformat()}\n",
          "# PART 1: PRODUCT LIFECYCLE (End of Order / End of Support)\n"]
if lc_new or lc_upd:
    blocks.append("# Lifecycle announcements that are NEW or CHANGED since the last run\n")
    blocks += [item_block(l, i) for l, g in (("NEW", lc_new), ("UPDATED", lc_upd)) for i in g]
else:
    blocks.append("No new or changed lifecycle announcements since the last run.\n")
if days > 0:
    blocks.append(f"# Upcoming lifecycle milestones: {len(upcoming)} item(s) with a date "
                  f"between {today.isoformat()} and {horizon.isoformat()} (next {days} days)\n"
                  "Sorted by the soonest upcoming date. All of each item's milestones are shown.\n")
    for g in ("Hardware & VM", "Software", "Services"):
        rows = [r for _, grp, r in upcoming if grp == g]
        if rows:
            blocks.append(f"## {g} ({len(rows)})\n" + "\n".join(rows) + "\n")
    rows = [r for _, grp, r in upcoming if grp not in ("Hardware & VM", "Software", "Services")]
    if rows:
        blocks.append(f"## Other ({len(rows)})\n" + "\n".join(rows) + "\n")

blocks.append("# PART 2: OTHER NEW OR UPDATED ITEMS (security, firmware, bulletins, signatures)\n")
if other_new or other_upd:
    blocks += [item_block(l, i) for l, g in (("NEW", other_new), ("UPDATED", other_upd)) for i in g]
else:
    blocks.append("None today.\n")
if skipped:
    blocks.append("## Ignored by your ignore list (do not summarize)\n"
                  + "\n".join("- " + i["title"] for i in skipped) + "\n")
if errors:
    blocks.append("## Sources that failed to load today\n" + "\n".join("- " + e for e in errors))
open("new-items.md", "w").write("\n".join(blocks))

# Let Claude fetch only the sites the changed items link to.
domains = sorted({urlparse(i["link"]).hostname for i in new + upd if urlparse(i["link"]).hostname})
open("tools", "w").write("Read\n" + "".join(f"WebFetch(domain:{d})\n" for d in domains))

soon30 = sum(1 for d, _, _ in upcoming if (d - today).days <= 30)
subj = f"EoL/EoS: {len(lc_new) + len(lc_upd)} new/changed, {len(upcoming)} due in {days}d"
if days > 30:
    subj += f" ({soon30} in 30d)"
if other_new or other_upd:
    subj += f" | {len(other_new)} new, {len(other_upd)} updated: " + \
            "; ".join(i["title"] for i in other_new + other_upd)
open("subject", "w").write(subj[:180].replace("\n", " "))
print(f"Lifecycle: {len(lc_new)} new, {len(lc_upd)} updated, {len(upcoming)} upcoming "
      f"in {days}d; other: {len(other_new)} new, {len(other_upd)} updated - handing to Claude.")
