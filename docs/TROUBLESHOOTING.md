# Troubleshooting

Start with the log of the last run:

```bash
sudo journalctl -u claude-job@fortitldr -n 40 --no-pager -o cat
```

## `install.sh` stops with an error

Read the last lines it printed. The common ones:

| Message | Fix |
|---|---|
| `No config.env` | `cp config.example.env config.env`, then edit it |
| `Set FORTITLDR_FROM ... to your real address` | You left the example address in `config.env` |
| `SCHEDULE in config.env is not valid` | Check it with `systemd-analyze calendar "<value>"` |
| An `apt-get` error | The firewall blocks Ubuntu's mirrors. Allow outbound TCP 80/443 and re-run |
| `Run with sudo` | `sudo ./install.sh` |

The installer is safe to re-run after fixing the problem.

## `401 Invalid bearer token` / `Invalid API key` / `Please run /login`

The Claude token in `/etc/claude-agent/env` is missing or mangled. Check it without
printing the whole token:

```bash
sudo awk -F= '/^CLAUDE_CODE_OAUTH_TOKEN/{v=substr($0,index($0,"=")+1); print "starts:", substr(v,1,13); print "length:", length(v); print "bad chars:", (v ~ /[[:space:]"\047]/ ? "YES" : "no")}' /etc/claude-agent/env
```

A good token **starts with** `sk-ant-oat01-`, is **about 100 or more characters**
long, and has **no** spaces, quotes or line breaks. A token that starts with
`sk-ant-api03-` is an API key, which doesn't go in this variable.

To fix it, run `setup-token` again with a wide terminal window, so the token doesn't
wrap, and paste it as one line. Only the most recently made token is sure to work.

The env file format is `KEY=value`, one per line, with no `export` and no spaces
around `=`. Check that Claude works on its own (it should reply "ok"):

```bash
sudo systemd-run --wait --pty -p User=claude-agent -p EnvironmentFile=/etc/claude-agent/env \
  /home/claude-agent/.local/bin/claude -p "say ok"
```

Other causes: the clock is off (run `timedatectl`), or `api.anthropic.com` is blocked
(`curl -sI https://api.anthropic.com | head -1` should print an HTTP status line).

## `Main process exited, status=1/FAILURE` with no detail

Look further up the log for `Claude failed:` or `pre.sh failed`. Very old installs
hid Claude's error inside the report file. Re-running `install.sh` fixes that.

## `cd: /home/claude-agent: Permission denied`

This is expected: the folder is private. Use `sudo` with full paths, for example
`sudo nano /home/claude-agent/agents/jobs/fortitldr/feeds`. Keep your clone of the
repo in your own home folder, not in `/home/claude-agent`.

## The job folder or `/home/claude-agent/agents` is missing

The installer stopped early. Run `sudo ./install.sh` again and read its last lines.

## The email doesn't arrive

```bash
sudo tail /home/claude-agent/.msmtp.log
```

| Symptom | Fix |
|---|---|
| Authentication failed | Wrong SMTP token, or a token made for a different address (Proton tokens are per address). Re-run `install.sh` and answer **y** |
| Connection timed out | Port 587 is blocked: `sudo ufw allow out 587/tcp` |
| Nothing in the log | Nothing changed, so no email was sent. Force a test with `force-latest` (see [MANAGING.md](MANAGING.md)) |
| The email is in spam | Add a filter or allow rule for your `[FortiTLDR]` subject tag |

If an email fails, nothing is marked as seen, so the same items are retried on the
next run.

## The same web page triggers an email every day

The page has content that changes on its own (dates, counters, ads). Use the site's
RSS feed if it has one, or remove the URL from `feeds`.

## Firmware items have no details

Links to `support.fortinet.com` need a login, so Claude uses the feed's title and
summary (product and version) instead. The release notes are on
<https://docs.fortinet.com>.

## `scp` into `/home/claude-agent` fails

`scp` can't write into the private folder. Use `git clone` / `git pull` in your own
home folder instead, then `sudo ./install.sh`.
