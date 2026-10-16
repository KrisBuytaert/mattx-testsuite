#!/bin/bash
# poll-and-dispatch.sh -- run from a systemd timer as forgejo-runner-mattx.
# For each tracked mattx branch, compares (branch tip, testsuite master tip)
# with the last tested pair and dispatches the Forgejo workflow when either
# changed. A pair whose long (EESSI) suites were held back by the workflow's gate
# (newer commit arrived mid-run) is rerun once its branch tip has been unchanged for
# QUIET_HOURS. One dispatch per tick, and none while a run is queued or running
# (state is only recorded when a run finishes). Idle project = a few
# ls-remote calls and one API read.
#
# Env (from a root-only env file):
#   FORGEJO_URL    e.g. http://127.0.0.1:3020
#   FORGEJO_TOKEN  token allowed to read and dispatch Actions on vox/mattx-testsuite
#   FORGEJO_CA     CA bundle for the self-signed instance (optional)
#   QUIET_HOURS    how long a branch tip must be unchanged before pending long suites run (default 6)
#   DRY_RUN=1      print the decision, dispatch nothing
set -euo pipefail
STATE_DIR="${STATE_DIR:-$HOME}"
BRANCHES="${BRANCHES:-1.9-dev main}"
MATTX_URL="${MATTX_URL:-https://github.com/brainmatt/mattx}"
TEST_URL="${TEST_URL:-https://github.com/KrisBuytaert/mattx-testsuite}"
QUIET_HOURS="${QUIET_HOURS:-6}"
REPO="${REPO:-vox/mattx-testsuite}"
api() { curl -fsS ${FORGEJO_CA:+--cacert "$FORGEJO_CA"} -H "Authorization: token $FORGEJO_TOKEN" "$@"; }

active=$(api "$FORGEJO_URL/api/v1/repos/$REPO/actions/tasks?limit=20" | python3 -c '
import json,sys
print(sum(1 for t in json.load(sys.stdin).get("workflow_runs",[]) if t.get("status") in ("running","waiting","queued","blocked")))')
[ "$active" = 0 ] || { echo "run active ($active), skipping"; exit 0; }

tests=$(git ls-remote "$TEST_URL" refs/heads/master | cut -f1)
[ -n "$tests" ] || { echo "testsuite ls-remote failed" >&2; exit 1; }

for b in $BRANCHES; do
    mattx=$(git ls-remote "$MATTX_URL" "refs/heads/$b" | cut -f1)
    [ -n "$mattx" ] || { echo "no such branch $b" >&2; continue; }
    now="$mattx $tests"
    # when did this pair first appear? (ls-remote gives no commit date)
    if [ "$(cut -d' ' -f1-2 "$STATE_DIR/seen.$b" 2>/dev/null)" != "$now" ]; then echo "$now $(date +%s)" > "$STATE_DIR/seen.$b"; fi
    if [ "$(cat "$STATE_DIR/last-tested.$b" 2>/dev/null)" = "$now" ]; then
        # tested; rerun only if the long suites are still owed and the branch has been quiet
        [ "$(cat "$STATE_DIR/last-eessi.$b" 2>/dev/null)" = "$now" ] && continue
        age=$(( $(date +%s) - $(cut -d' ' -f3 "$STATE_DIR/seen.$b") ))
        [ "$age" -ge $(( QUIET_HOURS * 3600 )) ] || continue
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then echo "would dispatch $b mattx=${mattx:0:7} tests=${tests:0:7}"; exit 0; fi
    api -X POST -H 'Content-Type: application/json' \
        -d "{\"ref\":\"master\",\"inputs\":{\"mattx_ref\":\"$b\"}}" \
        "$FORGEJO_URL/api/v1/repos/$REPO/actions/workflows/mattx-ci.yml/dispatches"
    echo "dispatched $b mattx=${mattx:0:7} tests=${tests:0:7}"
    exit 0
done
