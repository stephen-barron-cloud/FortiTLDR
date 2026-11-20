# Managing FortiTLDR

The job's live files are on the server in
**`/home/claude-agent/agents/jobs/fortitldr/`**. That folder is private, so:

- always use `sudo` and type the **full path** (tab-completion doesn't work there)
- don't `cd` into it, and don't loosen its permissions

Changes to these files apply on the next run. No restart is needed.

## What the briefing covers

Every briefing has up to four sections, most important first. The training and
news section is left out on days with nothing in it, and lifecycle becomes section 3:

1. **TL;DR**: security items that need action and what to do, a clause on other
   news, and one short sentence on upcoming lifecycle dates.
2. **Security**: what needs action (critical/high PSIRT advisories, anything
   exploited or in CISA KEV, CSBs that need you to act), each with a "More info:"
   link; then critical CVEs trending across the internet for other vendors' products
   (see below); then other advisories, outbreak alerts, threat signals and Threat
   Research posts; then firmware releases and signature updates.
3. **Training, Industry News and Announcements**: press releases, CISO Collective,
   Industry Trends and other blog posts.
4. **Product lifecycle**: new End of Order / End of Support announcements, then every
   milestone due in the next `LIFECYCLE_DAYS` days (default 90). Both are ordered by
   criticality first, then Hardware & VM / Software / Services, then product family
   (most commonly deployed first), then date. Only the major platforms get a
   color: FortiGate / FortiOS, FortiSwitch, FortiAP / Wireless, FortiManager,
   FortiAnalyzer, FortiClient / EMS and FortiAuthenticator (the `MAJOR` list in
   `job/pre.sh`). All other products are grey. The upcoming list is recalculated every
   run, so the email is sent daily while anything is upcoming. It comes last
   because it is planning information, not a security emergency.

### Trending CVEs from all vendors

The Intruder CVEMon feed lists the 10 CVEs most discussed online right now, for any
vendor. Your customers run that software behind Fortinet gear, so `job/pre.sh` looks
up each new one in NVD (CVSS score, publish date) and the CISA Known Exploited
Vulnerabilities (KEV) catalog, and marks it a **new threat** (published or added to
KEV in the last 14 days, `FRESH_DAYS`) or an **old threat trending again**.

- Fortinet CVEs are reported like any PSIRT advisory.
- Other vendors' CVEs are listed under "Trending threats from other vendors" only
  when critical: CVSS 9.0+, in CISA KEV, or exploited in the wild. Each says which
  Fortinet layer is relevant (IPS, FortiWeb, FortiEDR ...).
- Colors: new and exploited = red; new = orange; old but exploited = orange; old =
  yellow. **An old threat never turns the banner red**, however exploited it is:
  trending only means people are talking about it again.

If NVD or CISA can't be reached (see [FIREWALL.md](FIREWALL.md)), the briefing still
goes out with severity marked unknown.

**CVE links point to CVE.org**, the official CVE List. Each trending CVE links first
to its CVE.org record (`https://www.cve.org/CVERecord?id=...`), then its source page,
then its NVD page. Every CVE ID in the TL;DR is linked to its CVE.org record;
`job/render.py` checks the CVE.org API (`cveawg.mitre.org`) first and writes
"(not published on cve.org)" or "(rejected on cve.org)" instead of a link when that
applies. NVD is still used for CVSS scores and publish dates.

The email is dark-themed HTML in a neutral system font, with a plain-text version for mail
apps that don't show HTML. Items are color-coded by importance:

| Color | Tag | Used for |
|---|---|---|
| Red | `URGENT` | Security only: critical (CVSS 9+), actively exploited or CISA KEV |
| Orange | `HIGH` | Security only: high severity (CVSS 7-8.9), CSBs that need action, exploited outbreaks |
| Yellow | `MEDIUM` | Medium severity; End of Support or End of Engineering Support within 30 days for FortiGate 40-1000 series, FortiGate VMs, FortiOS, FortiSwitch below the 2000 series, FortiAP, FortiAuthenticator, FortiAnalyzer or FortiManager (`medium_eligible` in `job/pre.sh`); any NEW End of Order / End of Support announcement for FortiGate, FortiSwitch, FortiAP, FortiAnalyzer, FortiManager or FortiSASE hardware or VMs (`NEW_HW_MEDIUM` in `job/pre.sh`) |
| Green | `LOW` | Informational: threat research, firmware, signatures, news, other lifecycle dates for major platforms |
| Grey | `INFO` | No priority: lifecycle dates for products that are not major platforms |

Lifecycle items are never red or orange. The banner at the top follows the TL;DR,
not the most severe item in the email. It is red only when that day's feeds report
a new major security event or escalate an existing one (a new critical or exploited
Fortinet advisory, a new CISA KEV listing, a new outbreak alert about an exploited
Fortinet product, or an update that raises one of these). It is orange when other
security action is needed, and green otherwise. Lifecycle dates, firmware and news
never raise it. Lifecycle colors are set by `pre.sh`; security colors and the
TL;DR tag are chosen by Claude using the rules in `prompt.md`. Each run also saves the HTML next to the text report
(`reports/fortitldr/latest.html`).

Every email ends with a footer linking to the GitHub repo (`job/footer`). The family
order is the `FAMILIES` list in `job/pre.sh`.

Products you don't care about can be removed with the `ignore` file (below). To change
the window, set `LIFECYCLE_DAYS` in `config.env` and re-run `sudo ./install.sh`
(`0` turns the upcoming list off).

| File | What it controls | Who changes it |
|---|---|---|
| `feeds` | Which feeds and pages are watched | You, on the server |
| `ignore` | Topics to skip | You, on the server |
| `email`, `subject-prefix`, `lifecycle-days` | Recipient, subject tag, lifecycle window | `install.sh`, from `config.env` |
| `prompt.md`, `pre.sh`, `post.sh`, `footer`, `render.py` | How the briefing is built | `install.sh`, from the repo |
| `seen.json`, `snapshots/` | What has already been reported | The job itself |

---

## Add or remove sources

```bash
sudo nano /home/claude-agent/agents/jobs/fortitldr/feeds
```

One URL per line; `#` comments a line out. Save with **Ctrl+O, Enter**, exit with
**Ctrl+X**.

- **RSS/Atom feeds** work best: every new or changed post is reported.
- **Plain web pages** work too: you get a text diff whenever the page changes. Pages
  with dates, counters or ads in them can trigger an email every day, so use a feed
  when the site has one.
- **A new URL** is baselined silently on its first run, so you only hear about it
  once something changes. (Lifecycle milestones from a new lifecycle feed still
  appear in the upcoming list right away, because that list is worked out from
  dates, not from what is new.)
- **A URL that fails** is listed at the bottom of that day's email. The others are
  still checked.

### Default feeds

| Group | Feed | Notes |
|---|---|---|
| Security | `https://filestore.fortinet.com/fortiguard/rss/ir.xml` | PSIRT advisories (FG-IR-…) |
| Security | `https://filestore.fortinet.com/fortiguard/rss/outbreakalert.xml` | Outbreak Alerts |
| Security | `https://filestore.fortinet.com/fortiguard/rss/threatsignal.xml` | Threat Signal reports |
| Releases and support | `https://support.fortinet.com/rss/firmware.xml` | Firmware releases |
| Releases and support | `https://pub.kb.fortinet.com/rss/csb.xml` | Customer Support Bulletins (CSB-…) |
| Product lifecycle | `https://support.fortinet.com/rss/Hardware.xml` | Hardware & VM: End of Order / End of Support dates (~1,500 items) |
| Product lifecycle | `https://support.fortinet.com/rss/Software.xml` | Software: End of Order / End of Support dates (~800 items) |
| Product lifecycle | `https://support.fortinet.com/rss/Services.xml` | Services: End of Order / End of Support dates |
| Signature updates | `https://filestore.fortinet.com/fortiguard/rss/appcontrol.xml` | Application Control database |
| Signature updates | `https://filestore.fortinet.com/fortiguard/rss/otips.xml` | OT IPS signatures |
| Signature updates | `https://filestore.fortinet.com/fortiguard/rss/otapp.xml` | OT Application Control signatures |
| Security | `https://feeds.fortinet.com/fortinet/blog/threat-research` | Threat Research blog (FortiGuard Labs) |
| News | `https://feeds.fortinet.com/fortinet/blog/ciso-collective` | CISO Collective blog |
| News | `https://feeds.fortinet.com/fortinet/blog/industry-trends` | Industry Trends blog |
| News | `https://feeds.fortinet.com/fortinet/press-releases` | Press releases |

The lifecycle feeds are the RSS versions of the Hardware & VM, Software and Services
tabs on Fortinet's Product Life Cycle page,
<https://support.fortinet.com/welcome/#/lifecycle>, which has the full tables and
search. They are large but are baselined silently like any new URL, so you
only hear about milestones added or changed after install. The signature-update
feeds publish several times a week; comment them out if you don't need them.

### More feeds

The full catalogue of official FortiGuard feeds is at
<https://www.fortiguard.com/rss-feeds>. Most follow the pattern
`https://filestore.fortinet.com/fortiguard/rss/<name>.xml`; paste any of them into
`feeds`.

## Ignore topics you don't care about

```bash
sudo nano /home/claude-agent/agents/jobs/fortitldr/ignore
```

```
# Plain text = case-insensitive match anywhere in the item TITLE
FortiClient
FortiWeb
Joomla

# re: = regular expression (case-insensitive)
re:^FortiAnalyzer\b
re:\bFortiOS 6\.

# category: = a lifecycle item's Category (exact name, or category:re:<regex>)
category:Accessory
category:Training
category:re:^Forti(Fone|Recorder)
```

- Only **titles** are checked (or the **Category** for `category:` lines), so an
  advisory that merely mentions a product in its text isn't dropped by accident.
- Ignore rules also remove products from the **upcoming lifecycle milestones** list.
  Lifecycle titles are model/SKU or version names (`FG-60F`, `FAN-336R-60F-60`,
  `FortiOS 7.0`), and categories are product lines (`FortiGate`, `FortiSwitch`,
  `Accessory`, `Training`…) as shown in brackets in the email.
- Ignored items are marked as seen and never come back.
- The email ends with one line listing what was ignored, so you notice an over-broad rule.
- If every change on a given day is ignored and no lifecycle milestone is upcoming,
  no email is sent.
- A broken `re:` line is skipped with a warning in the log.

## Change the recipient, subject tag, SMTP server or schedule

These settings live in `config.env` in your clone of the repo:

```bash
cd ~/FortiTLDR && nano config.env && sudo ./install.sh
```

When it asks about `.msmtprc`, answer **n** to keep your SMTP token, or **y** to
enter a new one. You must answer **y** if you changed `FORTITLDR_FROM`, `SMTP_HOST`
or `SMTP_PORT`.

Schedule examples (systemd `OnCalendar` format):

| Schedule | Value |
|---|---|
| Every day at 7:00 Central | `"*-*-* 07:00 America/Chicago"` |
| Weekdays at 6:30 | `"Mon..Fri 06:30 America/Chicago"` |
| Twice a day | `"*-*-* 07,16:00 America/Chicago"` |

The timer adds a random delay of up to 3 minutes. If the server is off at the
scheduled time, the run happens at boot.

**Mail filter:** set up a rule that matches "Subject contains `[FortiTLDR]`" (or your
tag). In Proton: **Settings → Filters → Add filter**.

## Replace the SMTP token only

Either re-run `sudo ./install.sh` and answer **y**, or edit the `password` line
directly:

```bash
sudo nano /home/claude-agent/.msmtprc
```

## Replace the Claude token

```bash
sudo -u claude-agent -H /home/claude-agent/.local/bin/claude setup-token
sudo nano /etc/claude-agent/env      # CLAUDE_CODE_OAUTH_TOKEN=<token>
```

The token must be one unbroken line with no quotes. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) if you get a `401`.

## Test

```bash
# 1. Change check only: no Claude, no email, no usage
sudo -u claude-agent -H bash -c 'cd ~/agents/jobs/fortitldr && ./pre.sh; echo "exit code: $?"'
#    exit 3 = nothing new and nothing upcoming, 0 = a briefing would be sent,
#    1 = every feed failed
#    see what it found:  sudo cat /home/claude-agent/agents/jobs/fortitldr/new-items.md

# 2. Full run with a real email (pretends the newest item of the first feed is new)
sudo -u claude-agent touch /home/claude-agent/agents/jobs/fortitldr/force-latest
sudo systemctl start claude-job@fortitldr

# 3. Test an ignore rule: add part of that newest title to `ignore`, repeat step 2,
#    and look for "Ignored: ..." and "Nothing new - skipping Claude." in the log.
```

## Logs and past briefings

```bash
sudo journalctl -u claude-job@fortitldr -n 50 --no-pager -o cat      # last run
sudo journalctl -u claude-job@fortitldr --since today --no-pager      # today
sudo ls /home/claude-agent/agents/reports/fortitldr/                  # every briefing
sudo cat /home/claude-agent/agents/reports/fortitldr/latest.md        # newest briefing
sudo tail /home/claude-agent/.msmtp.log                               # email log
systemctl list-timers 'claude-job-*' --no-pager                       # next run
```

## Pause, resume, uninstall

```bash
sudo systemctl disable --now claude-job-fortitldr.timer    # pause
sudo /opt/claude-agent/add-job.sh fortitldr "*-*-* 07:00 America/Chicago"   # resume
```

To uninstall completely:

```bash
sudo systemctl disable --now claude-job-fortitldr.timer
sudo rm -f /etc/systemd/system/claude-job-fortitldr.timer /etc/systemd/system/claude-job@.service
sudo systemctl daemon-reload
sudo rm -rf /opt/claude-agent /etc/claude-agent
sudo userdel -r claude-agent
```

## Start over from scratch (forget everything seen)

```bash
sudo rm -rf /home/claude-agent/agents/jobs/fortitldr/{seen.json,snapshots}
```

The next run records every current feed item as seen without reporting it, like a
fresh install. It still emails the upcoming End of Order / End of Support list
(unless `LIFECYCLE_DAYS=0`), so expect a briefing with "None" in the security and
new-announcement sections.

## Keep Claude Code up to date

Auto-updates are off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`). Update now and then:

```bash
sudo -u claude-agent -H /home/claude-agent/.local/bin/claude update
```
