#!/usr/bin/env bash
# Runs ~/agents/jobs/<name>/prompt.md through Claude Code headless.
# Optional files in the job folder:
#   tools      one allowed tool per line, e.g.  Read   or   WebFetch(domain:example.com)
#   max-turns  a number (default 30)
#   pre.sh     runs first; exit 0 = continue, exit 3 = nothing to do (skip Claude)
#   email      first line = address to email the report to (uses ~/.msmtprc)
#   subject    email subject (pre.sh may write this)
#   subject-prefix  fixed tag put in front of every subject, e.g. [Watch]
#   footer     text appended to every report/email after a "-- " separator
#   render.py  executable; given the report path, prints an HTML version. The email
#              is then sent as HTML with the report as its plain-text alternative.
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
if [ -s footer ]; then printf '\n\n-- \n' >> "${OUT}"; cat footer >> "${OUT}"; fi
ln -sf "${OUT}" "${OUT_DIR}/latest.md"
echo "Report written: ${OUT}"

HTML=""
if [ -x ./render.py ]; then
  HTML="${OUT%.md}.html"
  if ./render.py "${OUT}" > "${HTML}" && [ -s "${HTML}" ]; then
    ln -sf "${HTML}" "${OUT_DIR}/latest.html"
  else
    echo "render.py failed - sending plain text only" >&2; HTML=""
  fi
fi

if [ -f email ]; then
  TO="$(head -n1 email)"
  SUBJECT="$(head -n1 subject 2>/dev/null || echo "${JOB} report")"
  PREFIX="$(grep -vE '^\s*(#|$)' subject-prefix 2>/dev/null | head -n1 || true)"
  [ -n "${PREFIX}" ] && SUBJECT="${PREFIX} ${SUBJECT}"
  # RFC 2047-encode the subject if it has non-ASCII characters (e.g. curly quotes)
  if LC_ALL=C grep -q '[^ -~]' <<<"${SUBJECT}"; then
    SUBJECT="=?UTF-8?B?$(printf '%s' "${SUBJECT}" | base64 -w0)?="
  fi
  if [ -n "${HTML}" ]; then
    B="fortitldr-$(date +%s)-$$"
    { printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\n' "${TO}" "${SUBJECT}"
      printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "${B}"
      printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n' "${B}"
      base64 < "${OUT}"
      printf -- '\n--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: base64\n\n' "${B}"
      base64 < "${HTML}"
      printf -- '\n--%s--\n' "${B}"; } | msmtp -t
  else
    { printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n' "${TO}" "${SUBJECT}"
      cat "${OUT}"; } | msmtp -t
  fi
  echo "Emailed ${TO}"
fi

if [ -x ./post.sh ]; then ./post.sh; fi
