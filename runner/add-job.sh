#!/usr/bin/env bash
# Schedules (or reschedules) a job with a systemd timer.
# Usage: sudo /opt/claude-agent/add-job.sh <job-name> "<OnCalendar>"
#   e.g. sudo /opt/claude-agent/add-job.sh fortitldr "*-*-* 07:00 America/Chicago"
#        sudo /opt/claude-agent/add-job.sh fortitldr "Mon..Fri 07:00 America/Chicago"
set -euo pipefail
NAME="${1:?job name}"; WHEN="${2:?OnCalendar expression}"
[ -f "/home/claude-agent/agents/jobs/${NAME}/prompt.md" ] || {
  echo "Create /home/claude-agent/agents/jobs/${NAME}/prompt.md first"; exit 1; }
systemd-analyze calendar "${WHEN}" >/dev/null
cat > "/etc/systemd/system/claude-job-${NAME}.timer" <<UNIT
[Unit]
Description=Schedule for Claude job ${NAME}

[Timer]
OnCalendar=${WHEN}
Persistent=true
RandomizedDelaySec=3min
Unit=claude-job@${NAME}.service

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable "claude-job-${NAME}.timer" >/dev/null 2>&1
systemctl restart "claude-job-${NAME}.timer"
systemctl list-timers "claude-job-${NAME}.timer" --no-pager
