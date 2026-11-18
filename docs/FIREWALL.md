# Firewall

The server needs **no inbound access** except SSH for your own management. All of
FortiTLDR's traffic is outbound.

## What the server needs to reach

| Purpose | Destination | Port |
|---|---|---|
| Claude (required) | `api.anthropic.com` → `160.79.104.0/23`, `153.61.224.0/22` | TCP 443 |
| Claude Code installer and updates | `claude.ai`, `downloads.claude.ai` (CDN, so its IPs change) | TCP 443 |
| Fortinet feeds | `filestore.fortinet.com`, `support.fortinet.com`, `pub.kb.fortinet.com`, `feeds.fortinet.com` (blogs and press releases) | TCP 443 |
| Pages Claude reads for details | `fortiguard.fortinet.com`, `www.fortinet.com`, plus the hosts of any feeds you add | TCP 443 |
| Email | your SMTP server, e.g. `smtp.protonmail.ch` | TCP 587 |
| DNS | your resolver only | 53 |
| Time sync (auth fails if the clock is off by more than 5 min) | NTP servers | UDP 123 |
| Ubuntu packages | `archive.ubuntu.com`, `security.ubuntu.com` | TCP 80, 443 |

Anthropic says its API ranges
["will not change without notice"](https://platform.claude.com/docs/en/api/ip-addresses).
Claude Code only talks to Anthropic, never to OpenAI.

## Where traffic comes from

- **Feeds** are downloaded by the server itself (`pre.sh`).
- **Pages Claude reads** (WebFetch) are also downloaded by the server itself. Before
  each fetch, only the hostname is sent to `api.anthropic.com` for a safety check.
- **The briefing text** is generated through `api.anthropic.com`.

## Recommended `ufw` rules (allow internet, block LAN)

Rules for websites can't be IP-based, because CDN addresses keep changing. Instead,
allow outbound web traffic but block your LAN. The deny rules must come before the
general allow. Adjust the subnets for your network.

```bash
sudo ufw default deny incoming
sudo ufw default deny outgoing
sudo ufw allow in from 192.168.1.0/24 to any port 22 proto tcp   # admin SSH
sudo ufw allow out to 192.168.1.1 port 53                         # your DNS server only
sudo ufw allow out 123/udp
sudo ufw deny out to 10.0.0.0/8
sudo ufw deny out to 172.16.0.0/12
sudo ufw deny out to 192.168.0.0/16
sudo ufw deny out to 169.254.0.0/16
sudo ufw allow out 80,443/tcp
sudo ufw allow out 587/tcp                                        # SMTP
sudo ufw enable
```

If you run a FortiGate in front of the server, you can apply the same policy there,
plus web filtering and application control on the server's address.

## Stricter: domain allowlist via a proxy

For real per-domain control, run a filtering proxy (for example Squid in an LXC, or
an explicit proxy on a FortiGate) that allows only the hosts above. Then point
Claude Code at it in `/etc/claude-agent/env`:

```ini
HTTPS_PROXY=http://<proxy-ip>:3128
NO_PROXY=localhost,127.0.0.1
```

`pre.sh` (Python `urllib`) also honors `HTTPS_PROXY`. SMTP doesn't go through an HTTP
proxy, so allow port 587 to your mail server directly.
