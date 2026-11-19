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
import datetime, difflib, hashlib, html, json, os, re, sys, time, urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urlparse

# Line-buffer output so every line reaches the systemd journal.
sys.stdout.reconfigure(line_buffering=True)

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
                              src=src or url, hash=sha(title + "\n" + VOLATILE.sub("", desc))))
        return items
    title, body = page_text(raw)
    return [dict(guid="page:" + url, title=title or url, link=url, date="", desc="",
                 src=url, hash=sha(body), body=body)]

# Parts of an item that change without the item really changing; left out of the
# hash so they don't report the item as UPDATED (e.g. CVEMon's hourly Hype Score).
VOLATILE = re.compile(r"Hype Score:\s*\d+")

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
        i["feed"] = url
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

# ---- Severity of trending CVEs from all vendors (Intruder CVEMon) ----
# CVEMon items carry no CVSS score or exploitation status, so each new or updated one
# is looked up in NVD (CVSS) and the CISA Known Exploited Vulnerabilities catalog.
# The result is added to the item's summary. A failed lookup (e.g. the host is not on
# your firewall allowlist) is noted there and never stops the run.
NVD = "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId="
KEV = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
CVE_ID = re.compile(r"CVE-\d{4}-\d{4,}", re.I)
# A trending CVE is a NEW threat if NVD published it, or CISA added it to KEV, within
# this many days. Anything older is an OLD threat that is trending again: still
# reported, but it never turns the briefing red.
FRESH_DAYS = 14

def fetch_json(url, timeout=20):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return json.load(r)

def to_date(s):
    try:
        return datetime.date.fromisoformat((s or "")[:10])
    except ValueError:
        return None

def nvd_lookup(cve):
    """(CVSS text or None, publish date or None) from NVD."""
    vulns = fetch_json(NVD + cve).get("vulnerabilities") or []
    rec = vulns[0]["cve"] if vulns else {}
    metrics, cvss = rec.get("metrics", {}), None
    for key in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30", "cvssMetricV2"):
        ms = metrics.get(key) or []
        if ms:
            m = next((x for x in ms if x.get("type") == "Primary"), ms[0])
            d = m["cvssData"]
            sev = d.get("baseSeverity") or m.get("baseSeverity", "")
            cvss = f"{d.get('baseScore')} {sev} (CVSS v{d.get('version')})"
            break
    return cvss, to_date(rec.get("published"))

cve_items = [i for i in new + upd if "cvemon.intruder.io" in i["feed"].lower()]
if cve_items:
    try:
        kev = {v["cveID"].upper(): v for v in fetch_json(KEV, 15)["vulnerabilities"]}
    except Exception as e:
        kev = None
        print(f"WARN CISA KEV lookup failed: {e}", file=sys.stderr)
    # NVD is often slow or throttled: retry each CVE once, and only give up on NVD
    # for the rest of the run after two CVEs in a row fail (it is likely blocked).
    nvd_fails, first = 0, True
    for i in cve_items:
        m = CVE_ID.search(i["title"])
        if not m:
            continue
        cve, facts, cvss, published = m.group(0).upper(), [], None, None
        for attempt in range(2 if nvd_fails < 2 else 0):
            if not first:
                time.sleep(6.5)   # NVD allows 5 requests per 30 seconds without an API key
            first = False
            try:
                score, published = nvd_lookup(cve)
                cvss = "CVSS " + (score or "not yet scored by NVD")
                nvd_fails = 0
                break
            except Exception as e:
                print(f"WARN NVD lookup for {cve} failed (try {attempt + 1}): {e}",
                      file=sys.stderr)
        else:
            if nvd_fails < 2:
                nvd_fails += 1
        facts.append(cvss or "CVSS unknown (NVD lookup failed)")
        now = datetime.date.today()
        age = lambda d: (now - d).days
        ago = lambda d: f"{age(d)} day{'' if age(d) == 1 else 's'} ago"
        if published:
            facts.append(f"published {published.isoformat()} ({ago(published)})")
        kev_added = None
        if kev is None:
            facts.append("CISA KEV status unknown (lookup failed)")
        elif cve in kev:
            k = kev[cve]
            kev_added = to_date(k.get("dateAdded"))
            facts.append(f"IN CISA KEV (known exploited), added {k.get('dateAdded')}"
                         + (f" ({ago(kev_added)})" if kev_added else "")
                         + f": {k.get('vendorProject')} {k.get('product')}"
                         + ("; used in ransomware campaigns"
                            if k.get("knownRansomwareCampaignUse") == "Known" else ""))
        else:
            facts.append("not in CISA KEV")
        # Freshness verdict. With no NVD date and no KEV entry, the CVE year is the
        # only clue: a CVE from an earlier year is old news.
        recent = [d for d in (published, kev_added) if d and age(d) <= FRESH_DAYS]
        if recent:
            status = "NEW THREAT"
        elif published or kev_added or int(cve.split("-")[1]) < now.year:
            first_seen = min(d for d in (published, kev_added) if d) if (published or kev_added) else None
            status = ("OLD THREAT, trending again (known since "
                      + (str(first_seen.year) if first_seen else cve.split("-")[1]) + ")")
        else:
            status = "NEW THREAT (date unconfirmed)"
        i["desc"] = ((i["desc"] or "n/a") + "\n- Looked up by the script: " + "; ".join(facts)
                     + f"\n- Status: {status}")
        i["nvd"] = "https://nvd.nist.gov/vuln/detail/" + cve

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

# Lifecycle items are ordered by how widely deployed the product family is.
# (label, regex on the family key) - most common first; unmatched families follow
# alphabetically, then accessories, modules, training and professional services.
FAMILIES = [
    ("FortiGate / FortiOS", r"^(FortiGate(?!-?ONE|Voice)|FortiOS|FortiCarrier|FortiController|FortiChassis)"),
    ("FortiSwitch", r"^(FortiSwitch|FortiLink)"),
    ("FortiAP / Wireless", r"^(FortiAP|ControllerWireless|Meru|FortiWLC|FortiWLM|FortiWiFi)"),
    ("FortiManager", r"^FortiManager"),
    ("FortiAnalyzer", r"^FortiAnalyzer"),
    ("FortiClient / EMS", r"^(FortiClient|FortiEndpoint)"),
    ("FortiToken", r"^FortiToken"),
    ("FortiAuthenticator", r"^FortiAuthenticator"),
    ("FortiExtender", r"^FortiExtender"),
    ("FortiCare / FortiGuard / Cloud services", r"^(FortiCare|FortiCloud|LicensesAndServices|FortiGuard)"),
    ("FortiSASE", r"^FortiSASE"),
    ("FortiEDR", r"^(FortiEDR|enSilo)"),
    ("FortiMail", r"^FortiMail"),
    ("FortiWeb", r"^FortiWeb"),
    ("FortiSandbox", r"^FortiSandbox"),
    ("FortiNAC", r"^FortiNAC"),
    ("FortiSIEM", r"^FortiSIEM"),
    ("FortiProxy", r"^FortiProxy"),
    ("FortiADC", r"^FortiADC"),
]
LAST = r"^(Accessory|Modules|Training|ProfessionalServices)$"
# Major platforms most Fortinet customers run. Their lifecycle dates get a color;
# every other product's dates are grey (no priority).
MAJOR = {"FortiGate / FortiOS", "FortiSwitch", "FortiAP / Wireless", "FortiManager",
         "FortiAnalyzer", "FortiClient / EMS", "FortiAuthenticator"}
# Within the major platforms, only these products turn [MEDIUM] when End of Support
# is within 30 days (matched on the item title); other major products stay [LOW].
def medium_eligible(title):
    t = title.strip()
    m = re.match(r"FortiGate-(\d+)", t, re.I)          # FortiGate 40-1000 series
    if m:
        return 40 <= int(m.group(1)) < 1100
    if re.match(r"FortiGate-VM", t, re.I):              # FortiGate VMs
        return True
    if re.match(r"FortiOS\b", t, re.I):                 # FortiOS releases
        return True
    m = re.match(r"FortiSwitch-(\d+)", t, re.I)        # FortiSwitch below 2000 series
    if m:
        return int(m.group(1)) < 2000
    return bool(re.match(r"(FortiAP|FortiAuthenticator|FortiAnalyzer|FortiManager)"
                         r"(-|\s+v?\d|$)", t, re.I))
GROUPS = ["Hardware & VM", "Software", "Services"]
LEVEL_RANK = {"[URGENT]": 0, "[HIGH]": 1, "[MEDIUM]": 2, "[LOW]": 3, "[INFO]": 4}
LEVEL_NAME = {"[MEDIUM]": "Medium", "[LOW]": "Low", "[INFO]": "Info (other products)"}
def family(i):
    """(rank, label) for a lifecycle item; key = Category, or product name for Software."""
    key = category(i) or re.sub(r"\s+v?\d.*$", "", i["title"])
    key = re.sub(r"\s*\(.*?\)", "", key).strip()   # "FortiPortal (Formerly ...)" -> "FortiPortal"
    for n, (label, rx) in enumerate(FAMILIES):
        if re.search(rx, key, re.I):
            return (n, label)
    if re.search(LAST, key, re.I):
        return (len(FAMILIES) + 2, key)
    return (len(FAMILIES) + 1, key)

try:
    days = int(open("lifecycle-days").read().strip())
except (FileNotFoundError, ValueError):
    days = 90
today = datetime.date.today()
horizon = today + datetime.timedelta(days=days)
cut = today + datetime.timedelta(days=30)

def lc_line(i, ms):
    dates = "; ".join(f"{n} {d.isoformat()}" + (f" (in {(d - today).days} days)"
                      if today <= d <= horizon else "") for n, d in ms)
    cat = category(i)
    return (f"- {i['title']}" + (f" [{cat}]" if cat else "") +
            f" ({lc_group(i['feed'])}): {dates}")

# Importance tag. Lifecycle dates are planning items, never security emergencies,
# so they never get [URGENT] or [HIGH]:
#   product not on the MAJOR list                                -> INFO (grey)
#   medium_eligible product, End of (Engineering) Support within 30 days -> MEDIUM
#   any other major platform item                                         -> LOW (green)
def lc_tag(ms, fam, title):
    if fam[1] not in MAJOR:
        return "[INFO]"
    soon = [(n, d) for n, d in ms if today <= d <= horizon]
    if medium_eligible(title) and any(d <= cut and "Support" in n for n, d in soon):
        return "[MEDIUM]"
    return "[LOW]"

def group_rank(i):
    g = lc_group(i["feed"])
    return GROUPS.index(g) if g in GROUPS else len(GROUPS)

upcoming, seen_rows = [], set()   # (family, soonest date, line)
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
        tag = lc_tag(ms, family(i), i["title"])
        upcoming.append((family(i), first, f"{tag} {family(i)[1]}: " + lc_line(i, ms)[2:],
                         tag, lc_group(i["feed"]), group_rank(i)))
# Criticality first, then Hardware & VM / Software / Services, then product family
# (most deployed first), then date.
upcoming.sort(key=lambda u: (LEVEL_RANK[u[3]], u[5], u[0], u[1], u[2]))

if not new and not upd and not upcoming:
    os.replace(PENDING, STATE)
    print(f"No changes across {len(ok)} source(s) and no lifecycle milestones in the next {days} days.")
    sys.exit(3)

# Non-lifecycle items, by the kind of feed they came from.
def kind(i):
    u = i["feed"].lower()
    if re.search(r"/rss/(ir|outbreakalert|threatsignal|epvuln|fmwp)\.xml$|csb\.xml$|/blog/threat-research|/blog/psirt|cvemon\.intruder\.io", u):
        return "security"
    if re.search(r"/rss/firmware\.xml$|filestore\.fortinet\.com/fortiguard/rss/", u):
        return "updates"
    return "news"

def item_block(label, i):
    return (f"## [{label}] {i['title']}\n- Source: {i['src']}\n- Link: {i['link']}\n"
            + (f"- NVD page: {i['nvd']}\n" if i.get("nvd") else "")
            + f"- Published: {i['date'] or 'n/a'}\n- Summary: {i['desc'] or 'n/a'}\n")
def blocks_for(pred):
    return [item_block(l, i) for l, g in (("NEW", new), ("UPDATED", upd)) for i in g if pred(i)]

lc_changed = sorted([i for i in new + upd if is_lifecycle(i)],
                    key=lambda i: (LEVEL_RANK[lc_tag(milestones(i), family(i), i["title"])],
                                   group_rank(i), family(i)))
sec = [i for i in new + upd if not is_lifecycle(i) and kind(i) == "security"]
ups = [i for i in new + upd if not is_lifecycle(i) and kind(i) == "updates"]
news = [i for i in new + upd if not is_lifecycle(i) and kind(i) == "news"]

blocks = [f"# Today is {today.isoformat()}\n"]

blocks.append("# PART 1: SECURITY (PSIRT advisories, outbreak alerts, threat signals, "
              "threat research, support bulletins, trending CVEs from all vendors)\n")
blocks += blocks_for(lambda i: i in sec) or ["None today.\n"]
blocks.append("# PART 1b: FIRMWARE RELEASES AND SIGNATURE UPDATES\n")
blocks += blocks_for(lambda i: i in ups) or ["None today.\n"]

blocks.append("# PART 2: TRAINING, INDUSTRY NEWS, PRESS RELEASES AND OTHER BLOG POSTS\n")
blocks += blocks_for(lambda i: i in news) or ["None today.\n"]

blocks.append("# PART 3: PRODUCT LIFECYCLE (End of Order / End of Support)\n"
              "Product families are listed most commonly deployed first.\n")
if lc_changed:
    blocks.append("## Lifecycle announcements that are NEW or CHANGED since the last run\n")
    for i in lc_changed:
        label = "NEW" if i in new else "UPDATED"
        blocks.append(f"- {lc_tag(milestones(i), family(i), i['title'])} [{label}] {family(i)[1]}: "
                      + lc_line(i, milestones(i))[2:])
    blocks.append("")
else:
    blocks.append("No new or changed lifecycle announcements since the last run.\n")
if days > 0:
    n30 = sum(1 for u in upcoming if u[1] <= cut)
    nmajor = sum(1 for u in upcoming if u[3] != "[INFO]")
    sections = []
    for u in upcoming:
        if (u[3], u[4]) not in sections:
            sections.append((u[3], u[4]))
    blocks.append(f"## Upcoming lifecycle milestones: {len(upcoming)} item(s) with a date "
                  f"between {today.isoformat()} and {horizon.isoformat()} (next {days} days)\n"
                  f"COUNTS (exact, computed by the script; use these, do not recount): "
                  f"{len(upcoming)} in the next {days} days, {n30} of them within 30 days; "
                  f"{nmajor} are for major platforms ({', '.join(sorted(MAJOR))}).\n"
                  "Grouped by criticality ([MEDIUM], then [LOW], then [INFO] for products "
                  "that are not major platforms), then Hardware & VM / Software / Services; "
                  "within each group by product family, most deployed first, then by "
                  "soonest date. All of each item's milestones are shown.\n")
    for tag, grp in sections:
        rows = ["- " + u[2] for u in upcoming if u[3] == tag and u[4] == grp]
        blocks.append(f"### {LEVEL_NAME.get(tag, tag)}: {grp} ({len(rows)})\n"
                      + "\n".join(rows) + "\n")

if skipped:
    blocks.append("## Ignored by your ignore list (do not summarize)\n"
                  + "\n".join("- " + i["title"] for i in skipped) + "\n")
if errors:
    blocks.append("## Sources that failed to load today\n" + "\n".join("- " + e for e in errors))
open("new-items.md", "w").write("\n".join(blocks))

# Let Claude fetch only the sites the changed items link to.
domains = sorted({urlparse(i["link"]).hostname for i in new + upd if urlparse(i["link"]).hostname})
open("tools", "w").write("Read\n" + "".join(f"WebFetch(domain:{d})\n" for d in domains))

soon30 = sum(1 for u in upcoming if u[1] <= cut)
parts = []
if sec:
    parts.append(f"Security: {len(sec)} - " + "; ".join(i["title"] for i in sec))
if ups:
    parts.append(f"{len(ups)} firmware/signature")
if news:
    parts.append(f"{len(news)} news")
parts.append(f"EoL/EoS: {len(lc_changed)} new/changed, {len(upcoming)} due in {days}d"
             + (f" ({soon30} in 30d)" if days > 30 else ""))
open("subject", "w").write(" | ".join(parts)[:180].replace("\n", " "))
print(f"Security {len(sec)}, updates {len(ups)}, lifecycle {len(lc_changed)} new/changed + "
      f"{len(upcoming)} upcoming in {days}d, news {len(news)} - handing to Claude.")
