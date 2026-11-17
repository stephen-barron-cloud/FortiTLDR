#!/bin/sh
[ -f seen.pending.json ] && mv seen.pending.json seen.json
for f in snapshots/*.pending; do [ -e "$f" ] && mv "$f" "${f%.pending}"; done
rm -f new-items.md subject
