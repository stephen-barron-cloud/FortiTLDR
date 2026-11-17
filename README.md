# FortiTLDR

**A daily email that tells you what changed in the Fortinet world, and what you need
to do about it.**

FortiTLDR runs on a small Ubuntu server (for example, a VM in a Proxmox homelab). Every
morning it checks Fortinet's official feeds for new security advisories, outbreak
alerts, threat reports and firmware releases. When something is new, it has Claude
read the details and email you a short briefing. An illustrative example:

```
Subject: [FortiTLDR] 3 new, 0 updated: FG-IR-26-112 FortiOS SSL-VPN ...; FortiOS 7.6.3 released; ...

TL;DR: One critical FortiOS advisory needs action today; two firmware releases.

ACTION NEEDED
- FortiOS SSL-VPN heap overflow (FG-IR-26-112, CVSS 9.6, exploited in the wild):
  upgrade to 7.4.9 / 7.6.3 or later.

DETAILS
Security advisories (PSIRT)
  ...
Firmware releases
  FortiOS 7.6.3, 7.4.9
...
```

Quiet days cost nothing: if no feed changed, Claude isn't called and no email is sent.

## What it watches (by default)

| Source | Feed |
|---|---|
| PSIRT security advisories | `https://filestore.fortinet.com/fortiguard/rss/ir.xml` |
| Outbreak Alerts | `https://filestore.fortinet.com/fortiguard/rss/outbreakalert.xml` |
| Threat Signal reports | `https://filestore.fortinet.com/fortiguard/rss/threatsignal.xml` |
| Firmware releases | `https://support.fortinet.com/rss/firmware.xml` |
| *Optional:* Fortinet blog, endpoint vulnerabilities, virtual patching | see [`job/feeds.default`](job/feeds.default) |

You can add any RSS/Atom feed or web page, and filter out topics you don't care about.
See [docs/MANAGING.md](docs/MANAGING.md).

## How it works

```
systemd timer (e.g. 07:00 daily)
  └─ claude-job@fortitldr.service           runs as the unprivileged user "claude-agent"
       └─ /opt/claude-agent/run-job.sh fortitldr
            1. pre.sh    fetch every feed, compare with the last run, apply the ignore list
                         (nothing new → stop: no Claude usage, no email)
            2. claude -p read the new items' pages and write the briefing
            3. msmtp     send it through your mail provider's SMTP server
            4. post.sh   mark the items as seen, only after the email was sent
```

- **Claude** runs as [Claude Code in headless mode](https://code.claude.com/docs/en/headless)
  with a Claude **Pro** (or Max) subscription. Each run counts toward your normal
  usage limits.
- **Claude can only read**: each run allows it to read the change list and fetch pages
  on the sites the new items link to. It has no shell access.
- **Change detection is plain code**, not AI. Every item is tracked by its ID and a hash
  of its content, so updated advisories are reported as UPDATED.

## Requirements

- An Ubuntu 22.04/24.04 server or VM (1 vCPU, 2 GB RAM is plenty) with outbound internet
- A Claude Pro or Max subscription
- An email account with SMTP access. The defaults are for **Proton Mail**, which needs a
  paid plan with a custom domain and an SMTP token. Gmail, Fastmail and Outlook work too.

## Quick start

On the server:

```bash
git clone https://github.com/stephen-barron-cloud/FortiTLDR.git
cd FortiTLDR
cp config.example.env config.env
nano config.env                   # your from/to addresses, SMTP server, schedule
sudo ./install.sh                 # asks for your SMTP token (hidden input)
```

> If the repo is private, run `sudo apt install gh && gh auth login` first and clone
> with `gh repo clone stephen-barron-cloud/FortiTLDR`.

Then connect Claude (one time):

```bash
sudo -u claude-agent -H /home/claude-agent/.local/bin/claude setup-token
# open the URL it prints, sign in, and copy the token
sudo nano /etc/claude-agent/env   # CLAUDE_CODE_OAUTH_TOKEN=<token>, one line, no quotes
```

Test it:

```bash
# Email works?
printf 'Subject: FortiTLDR test\n\nIt works.\n' | sudo -u claude-agent -H msmtp you@yourdomain.com

# First run: records today's items as the baseline (no email)
sudo systemctl start claude-job@fortitldr

# Full test: pretends the newest item is new, and sends a real briefing
sudo -u claude-agent touch /home/claude-agent/agents/jobs/fortitldr/force-latest
sudo systemctl start claude-job@fortitldr
sudo journalctl -u claude-job@fortitldr -n 30 --no-pager -o cat
```

That's it. The timer from `config.env` (default **07:00 America/Chicago**) is already
active. Check it with `systemctl list-timers 'claude-job-*'`.

## Privacy: what stays out of git

Your email addresses live only in **`config.env`**, which is listed in
[`.gitignore`](.gitignore). The SMTP token and Claude token are never written into
the repo at all:

| Secret | Where it lives on the server | Permissions |
|---|---|---|
| From/to addresses, schedule | `config.env` in your clone (git-ignored) | your user |
| SMTP token | `/home/claude-agent/.msmtprc` | `600`, claude-agent |
| Claude token | `/etc/claude-agent/env` | `600`, root |

`.gitignore` also excludes runtime state (`seen.json`, `snapshots/`, `reports/`) in
case you ever copy a job folder back into the repo.

## Repository layout

```
FortiTLDR/
├── install.sh              One-shot installer (safe to re-run)
├── config.example.env      Copy to config.env (git-ignored) and edit
├── job/                    The FortiTLDR job
│   ├── pre.sh              Feed fetch, change detection, ignore list
│   ├── post.sh             Saves state after a successful send
│   ├── prompt.md           Instructions Claude follows to write the briefing
│   ├── feeds.default       Starting list of feeds
│   └── ignore.default      Starting ignore list (examples, all commented out)
├── runner/
│   ├── run-job.sh          Runs one job: pre → Claude → email → post
│   └── add-job.sh          Creates/updates a job's systemd timer
├── systemd/
│   └── claude-job@.service Service template used by every job
└── docs/
    ├── MANAGING.md         Day-to-day: feeds, ignore list, schedule, testing, updates
    ├── FIREWALL.md         What the server needs to reach, and ufw rules
    └── TROUBLESHOOTING.md  Common problems and fixes
```

## Updating

```bash
cd ~/FortiTLDR && git pull && sudo ./install.sh     # answer n to keep your SMTP token
```

The installer updates the scripts and prompt. It never touches your feeds, ignore
list, Claude token or history.

> **Upgrading from the older `fortinet-watch` setup?** Just run `install.sh`. It moves
> the old job to `fortitldr`, keeps your feeds, ignore list and history, adds the new
> default Fortinet feeds, and replaces the old timer.

## License

[MIT](LICENSE). FortiTLDR is an independent project, not affiliated with or endorsed
by Fortinet. Fortinet, FortiGate, FortiGuard and FortiOS are trademarks of Fortinet, Inc.
Feed content belongs to its publishers.
