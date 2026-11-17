#!/usr/bin/env bash
# Runs ~/agents/jobs/<name>/prompt.md through Claude Code headless.
# Optional files in the job folder:
#   tools      one allowed tool per line, e.g.  Read   or   WebFetch(domain:example.com)
#   max-turns  a number (default 30)
#   pre.sh     runs first; exit 0 = continue, exit 3 = nothing to do (skip Claude)
#   email      first line = address to email the report to (uses ~/.msmtprc)
#   subject    email subject (pre.sh may write this)
#   subject-prefix  fixed tag put in front of every subject, e.g. [Watch]
#   post.sh    runs after a successful report/email (e.g. to save state)
set -euo pipefail
JOB="${1:?usage: run-job.sh <job-name>}"
BASE="${HOME}/agents"
JOB_DIR="${BASE}/jobs/${JOB}"
CLAUDE_BIN="${CLAUDE_BIN:-${HOME}/.local/bin/claude}"
[ -f "${JOB_DIR}/prompt.md" ] || { echo "Missing ${JOB_DIR}/prompt.md"; exit 1; }
cd "${JOB_DIR}"

if [ -x ./pre.sh ]; then
  set +e; ./pre.sh; rc=$?; set -e
  if [ "${rc}" -eq 3 ]; then echo "Nothing new - skipping Claude."; exit 0; fi
  [ "${rc}" -eq 0 ] || { echo "pre.sh failed (exit ${rc})"; exit "${rc}"; }
fi

ARGS=(-p "$(cat prompt.md)" --output-format text
      --max-turns "$(cat max-turns 2>/dev/null || echo 30)")
if [ -f tools ]; then
  TOOLS="$(grep -vE '^\s*(#|$)' tools | paste -sd, -)"
  [ -n "${TOOLS}" ] && ARGS+=(--allowedTools "${TOOLS}")
fi

OUT_DIR="${BASE}/reports/${JOB}"; mkdir -p "${OUT_DIR}"
OUT="${OUT_DIR}/$(date +%F_%H%M).md"
if ! "${CLAUDE_BIN}" "${ARGS[@]}" > "${OUT}"; then echo "Claude failed:" >&2; cat "${OUT}" >&2; exit 1; fi
[ -s "${OUT}" ] || { echo "Claude returned an empty report"; exit 1; }
ln -sf "${OUT}" "${OUT_DIR}/latest.md"
echo "Report written: ${OUT}"

if [ -f email ]; then
  TO="$(head -n1 email)"
  SUBJECT="$(head -n1 subject 2>/dev/null || echo "${JOB} report")"
  PREFIX="$(grep -vE '^\s*(#|$)' subject-prefix 2>/dev/null | head -n1 || true)"
  [ -n "${PREFIX}" ] && SUBJECT="${PREFIX} ${SUBJECT}"
  { printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n' "${TO}" "${SUBJECT}"
    cat "${OUT}"; } | msmtp -t
  echo "Emailed ${TO}"
fi

if [ -x ./post.sh ]; then ./post.sh; fi
