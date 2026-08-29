#!/bin/bash
# The three nightly host checks, one ping.
#
# They run minutes apart, are silent unless something is wrong, and are all
# investigated the same way — ssh to pve and read the log. Three separate
# healthchecks would be three places to look for one answer, so this runs them
# in order and reports once, naming whichever failed.
#
# Each sub-check prints to its own log and exits non-zero on a problem. That
# exit code is the whole interface; none of them ping anything themselves.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -uo pipefail

HC_URL="https://hc-ping.com/REPLACE-ME-SEE-PRIVATE-NOTES"
FAILED=""

for c in sas-health-check spindown-drift-check git-drift-check; do
  s="/root/scripts/$c.sh"
  if [ ! -x "$s" ]; then
    FAILED="$FAILED $c(missing)"
    continue
  fi
  out=$("$s" 2>&1); rc=$?
  printf '%s\n' "$out" >> "/var/log/${c}.log"
  [ "$rc" -ne 0 ] && FAILED="$FAILED $c"
done

if [ -n "$FAILED" ]; then
  echo "$(date '+%F %T') FAILED:$FAILED"
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "failed:$FAILED" "$HC_URL/fail" || true
  exit 1
fi

echo "$(date '+%F %T') ok (disk health, spin-down, git drift)"
curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
