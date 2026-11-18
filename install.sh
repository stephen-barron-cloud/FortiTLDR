#!/usr/bin/env bash
# FortiTLDR installer: sets up an Ubuntu server/VM to email a daily, Claude-written
# summary of Fortinet security announcements and product releases.
#
#   cp config.example.env config.env   # then edit it
#   sudo ./install.sh
#
# Safe to re-run at any time (after a `git pull`, or after editing config.env).
# It keeps your Claude token, feeds, ignore list and the record of seen items.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_USER="claude-agent"
AGENT_HOME="/home/${AGENT_USER}"
JOB="fortitldr"
JOBS_DIR="${AGENT_HOME}/agents/jobs"
JOB_DIR="${JOBS_DIR}/${JOB}"
BIN_DIR="/opt/claude-agent"
ENV_DIR="/etc/claude-agent"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run with sudo:  sudo ./install.sh"

# ---------- settings ----------
CONFIG="${REPO_DIR}/config.env"
[ -f "${CONFIG}" ] || die "No config.env. Create it first:
  cp ${REPO_DIR}/config.example.env ${CONFIG}
  nano ${CONFIG}"
# shellcheck source=/dev/null
. "${CONFIG}"
: "${SMTP_HOST:=smtp.protonmail.ch}" "${SMTP_PORT:=587}" "${SUBJECT_PREFIX:=[FortiTLDR]}"
: "${SCHEDULE:=*-*-* 07:00 America/Chicago}"
[[ "${LIFECYCLE_DAYS:=90}" =~ ^[0-9]+$ ]] || die "LIFECYCLE_DAYS in config.env must be a whole number of days (0 = off)."
for v in FORTITLDR_FROM FORTITLDR_TO; do
  val="${!v:-}"
  [[ "${val}" == *@*.* ]] || die "${v} in config.env is not an email address."
  [[ "${val}" != *yourdomain.com ]] || die "Set ${v} in config.env to your real address."
done
systemd-analyze calendar "${SCHEDULE}" >/dev/null 2>&1 || die "SCHEDULE in config.env is not valid: ${SCHEDULE}"

# ---------- packages ----------
say "Installing packages (curl, git, python3, msmtp)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq curl git jq ca-certificates python3 msmtp >/dev/null
timedatectl set-ntp true 2>/dev/null || true   # Claude auth fails if the clock drifts

# ---------- user + Claude Code ----------
say "Creating the ${AGENT_USER} user (runs the jobs, no sudo rights)"
id "${AGENT_USER}" &>/dev/null || useradd --create-home --shell /bin/bash "${AGENT_USER}"
install -d -o "${AGENT_USER}" -g "${AGENT_USER}" -m 750 "${AGENT_HOME}/agents" "${JOBS_DIR}" "${AGENT_HOME}/agents/reports"

if [ ! -x "${AGENT_HOME}/.local/bin/claude" ]; then
  say "Installing Claude Code"
  sudo -u "${AGENT_USER}" -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
fi
sudo -u "${AGENT_USER}" -H "${AGENT_HOME}/.local/bin/claude" --version

install -d -m 755 "${ENV_DIR}"
if [ ! -f "${ENV_DIR}/env" ]; then
  cat > "${ENV_DIR}/env" <<'EOF'
# One KEY=value per line. No "export", no spaces around "=", no quotes needed.
# Paste the token printed by `claude setup-token` (one unbroken line):
CLAUDE_CODE_OAUTH_TOKEN=
# Turn off telemetry, error reports and auto-updates (run `claude update` yourself)
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
EOF
fi
chown root:root "${ENV_DIR}/env"; chmod 600 "${ENV_DIR}/env"

# ---------- runner + systemd ----------
say "Installing the job runner and systemd service"
install -d -m 755 "${BIN_DIR}"
install -m 755 "${REPO_DIR}/runner/run-job.sh" "${REPO_DIR}/runner/add-job.sh" "${BIN_DIR}/"
install -m 644 "${REPO_DIR}/systemd/claude-job@.service" /etc/systemd/system/
systemctl daemon-reload

# ---------- migrate an older "fortinet-watch" install ----------
OLD="${JOBS_DIR}/fortinet-watch"
if [ -d "${OLD}" ] && [ ! -d "${JOB_DIR}" ]; then
  say "Migrating the old fortinet-watch job to ${JOB} (feeds, ignore list and history kept)"
  systemctl disable --now claude-job-fortinet-watch.timer 2>/dev/null || true
  rm -f /etc/systemd/system/claude-job-fortinet-watch.timer
  mv "${OLD}" "${JOB_DIR}"
  [ -d "${AGENT_HOME}/agents/reports/fortinet-watch" ] && \
    mv "${AGENT_HOME}/agents/reports/fortinet-watch" "${AGENT_HOME}/agents/reports/${JOB}"
  # Add the new default Fortinet feeds that the old list didn't have
  # (they are baselined silently on the next run).
  grep -vE '^\s*(#|$)' "${REPO_DIR}/job/feeds.default" | while read -r url; do
    grep -qxF "${url}" "${JOB_DIR}/feeds" || echo "${url}" >> "${JOB_DIR}/feeds"
  done
  systemctl daemon-reload
fi

# ---------- job files ----------
say "Installing the ${JOB} job in ${JOB_DIR}"
install -d -o "${AGENT_USER}" -g "${AGENT_USER}" -m 750 "${JOB_DIR}"
inst() { install -o "${AGENT_USER}" -g "${AGENT_USER}" -m "$1" "$2" "$3"; }
# Always updated from the repo:
inst 755 "${REPO_DIR}/job/pre.sh"    "${JOB_DIR}/pre.sh"
inst 755 "${REPO_DIR}/job/post.sh"   "${JOB_DIR}/post.sh"
inst 644 "${REPO_DIR}/job/prompt.md" "${JOB_DIR}/prompt.md"
# Created once; after that you manage them on the server:
[ -f "${JOB_DIR}/feeds" ]  || inst 644 "${REPO_DIR}/job/feeds.default"  "${JOB_DIR}/feeds"
[ -f "${JOB_DIR}/ignore" ] || inst 644 "${REPO_DIR}/job/ignore.default" "${JOB_DIR}/ignore"
[ -f "${JOB_DIR}/tools" ]  || { echo "Read" > "${JOB_DIR}/tools"; chown "${AGENT_USER}:" "${JOB_DIR}/tools"; }
# Written from config.env every time:
w() { printf '%s\n' "$2" > "${JOB_DIR}/$1"; chown "${AGENT_USER}:${AGENT_USER}" "${JOB_DIR}/$1"; }
w email          "${FORTITLDR_TO}"
w subject-prefix "${SUBJECT_PREFIX}"
w max-turns      "25"
w lifecycle-days "${LIFECYCLE_DAYS}"
chown -R "${AGENT_USER}:${AGENT_USER}" "${JOB_DIR}"

# ---------- email (SMTP) ----------
MSMTPRC="${AGENT_HOME}/.msmtprc"
WRITE_RC=yes
if [ -f "${MSMTPRC}" ]; then
  read -r -p $'\n'"${MSMTPRC} already exists. Replace it (new SMTP token or settings)? [y/N] " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || WRITE_RC=no
fi
if [ "${WRITE_RC}" = yes ]; then
  read -r -s -p "SMTP password/token for ${FORTITLDR_FROM} on ${SMTP_HOST} (hidden): " SMTP_TOKEN; echo
  [ -n "${SMTP_TOKEN}" ] || die "No SMTP token entered."
  ( umask 077
    cat > "${MSMTPRC}" <<EOF
# SMTP settings used by FortiTLDR. Written by install.sh. Keep private.
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        fortitldr
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${FORTITLDR_FROM}
user           ${FORTITLDR_FROM}
password       ${SMTP_TOKEN}

account default : fortitldr
EOF
  )
  unset SMTP_TOKEN
fi
chown "${AGENT_USER}:${AGENT_USER}" "${MSMTPRC}"; chmod 600 "${MSMTPRC}"

# ---------- schedule ----------
say "Scheduling: ${SCHEDULE}"
"${BIN_DIR}/add-job.sh" "${JOB}" "${SCHEDULE}"

# ---------- next steps ----------
printf '\n=========================== FortiTLDR installed ===========================\n'
if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=..' "${ENV_DIR}/env"; then
  echo "Claude token: set"
else
  cat <<'TOKEN'
Claude token: NOT SET - do this first:
  1) sudo -u claude-agent -H /home/claude-agent/.local/bin/claude setup-token
     (open the URL it prints, sign in, copy the token)
  2) sudo nano /etc/claude-agent/env    ->   CLAUDE_CODE_OAUTH_TOKEN=<token>
TOKEN
fi
cat <<DONE

Test email:
  printf 'Subject: FortiTLDR test\n\nIt works.\n' | sudo -u claude-agent -H msmtp ${FORTITLDR_TO}

First run (records today's items as the baseline, no email):
  sudo systemctl start claude-job@${JOB}

Full test (pretends the newest item is new, sends a real digest):
  sudo -u claude-agent touch ${JOB_DIR}/force-latest
  sudo systemctl start claude-job@${JOB}
  sudo journalctl -u claude-job@${JOB} -n 30 --no-pager -o cat

Manage it: see docs/MANAGING.md
===========================================================================
DONE
