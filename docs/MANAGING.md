# Managing FortiTLDR

The job's live files are on the server in
**`/home/claude-agent/agents/jobs/fortitldr/`**. That folder is private, so:

- always use `sudo` and type the **full path** (tab-completion doesn't work there)
- don't `cd` into it, and don't loosen its permissions

Changes to these files apply on the next run. No restart is needed.

## What the briefing covers

Product lifecycle comes first. Every briefing lists:

1. **New lifecycle announcements**: End of Order / End of Support items that are new
   or changed in Fortinet's Hardware & VM, Software and Services lifecycle feeds.
2. **Upcoming milestones**: every product whose End of Order, End of Engineering
   Support, Last Service Extension or End of Support date falls in the next
   `LIFECYCLE_DAYS` days (default 90), split into "within 30 days" and later. This
   is recalculated on every run, so the email is sent daily while anything is
   upcoming.
3. Security advisories and other new items (PSIRT, outbreak alerts, firmware, CSBs,
   signature updates), in shorter form.

Products you don't care about can be removed with the `ignore` file (below). To change
the window, set `LIFECYCLE_DAYS` in `config.env` and re-run `sudo ./install.sh`
(`0` turns the upcoming list off).

| File | What it controls | Who changes it |
|---|---|---|
| `feeds` | Which feeds and pages are watched | You, on the server |
| `ignore` | Topics to skip | You, on the server |
| `email`, `subject-prefix`, `lifecycle-days` | Recipient, subject tag, lifecycle window | `install.sh`, from `config.env` |
| `prompt.md`, `pre.sh`, `post.sh` | How the briefing is built | `install.sh`, from the repo |
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
  once something changes.
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

The next run re-baselines every feed silently.

## Keep Claude Code up to date

Auto-updates are off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`). Update now and then:

```bash
sudo -u claude-agent -H /home/claude-agent/.local/bin/claude update
```
