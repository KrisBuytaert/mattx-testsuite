#!/bin/bash
# poll-and-dispatch.sh -- run from a systemd timer as forgejo-runner-mattx.
# For each tracked (repo, branch) -- ci/tracked.conf -- compares (branch tip, testsuite
# master tip) with the last tested pair and dispatches the Forgejo workflow when either
# changed. A pair whose long (EESSI) suites were held back by the workflow's gate
# (newer commit arrived mid-run) is rerun once its branch tip has been unchanged for
# QUIET_HOURS. One dispatch per tick, and none while a run is queued or running
# (state is only recorded when a run finishes). Idle project = a few ls-remote calls
# and one API read.
#
# Fork branches (anything outside brainmatt/mattx) are followed until their PR into
# brainmatt/mattx is merged, then skipped.
#
# Env (from a root-only env file):
#   FORGEJO_URL    e.g. http://127.0.0.1:3020
#   FORGEJO_TOKEN  token allowed to read and dispatch Actions on vox/mattx-testsuite
#   FORGEJO_CA     CA bundle for the self-signed instance (optional)
#   QUIET_HOURS    how long a branch tip must be unchanged before pending long suites run (default 6)
#   TRACKED_URL    where to read tracked.conf (default: GitHub master of the testsuite)
#   DRY_RUN=1      print the decision, dispatch nothing
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-$HOME}"
UPSTREAM="${UPSTREAM:-brainmatt/mattx}"
TEST_URL="${TEST_URL:-https://github.com/KrisBuytaert/mattx-testsuite}"
TRACKED_URL="${TRACKED_URL:-https://raw.githubusercontent.com/KrisBuytaert/mattx-testsuite/master/ci/tracked.conf}"
QUIET_HOURS="${QUIET_HOURS:-6}"
REPO="${REPO:-vox/mattx-testsuite}"
api() { curl -fsS ${FORGEJO_CA:+--cacert "$FORGEJO_CA"} -H "Authorization: token $FORGEJO_TOKEN" "$@"; }

active=$(api "$FORGEJO_URL/api/v1/repos/$REPO/actions/tasks?limit=20" | python3 -c '
import json,sys
print(sum(1 for t in json.load(sys.stdin).get("workflow_runs",[]) if t.get("status") in ("running","waiting","queued","blocked")))')
[ "$active" = 0 ] || { echo "run active ($active), skipping"; exit 0; }

tests=$(git ls-remote "$TEST_URL" refs/heads/master | cut -f1)
[ -n "$tests" ] || { echo "testsuite ls-remote failed" >&2; exit 1; }

# tracked.conf from GitHub master (so a new branch needs no deploy); the copy next to
# this script, then the two upstream branches, if GitHub is unreachable.
conf=$(curl -fsS --max-time 20 "$TRACKED_URL" 2>/dev/null || cat "$HERE/tracked.conf" 2>/dev/null || printf 'brainmatt/mattx 1.9-dev\nbrainmatt/mattx main\n')

# Has the PR from this fork branch been merged upstream? (unauthenticated API, a few calls an hour)
merged_upstream() {
    local owner="${1%%/*}" ref="$2"
    curl -fsS --max-time 20 "https://api.github.com/repos/$UPSTREAM/pulls?state=all&head=$owner:$ref" 2>/dev/null |
        python3 -c 'import json,sys; sys.exit(0 if any(p.get("merged_at") for p in json.load(sys.stdin)) else 1)' 2>/dev/null
}

while read -r repo b _; do
    case "$repo" in ''|'#'*) continue ;; esac
    key=$("$HERE/branch-key.sh" "$repo" "$b")
    mattx=$(git ls-remote "https://github.com/$repo" "refs/heads/$b" | cut -f1)
    [ -n "$mattx" ] || { echo "no such branch $repo $b" >&2; continue; }
    if [ "$repo" != "$UPSTREAM" ] && merged_upstream "$repo" "$b"; then
        echo "$repo $b is merged upstream, no longer followed (remove it from tracked.conf)" >&2
        continue
    fi
    now="$mattx $tests"
    # when did this pair first appear? (ls-remote gives no commit date)
    if [ "$(cut -d' ' -f1-2 "$STATE_DIR/seen.$key" 2>/dev/null)" != "$now" ]; then echo "$now $(date +%s)" > "$STATE_DIR/seen.$key"; fi
    if [ "$(cat "$STATE_DIR/last-tested.$key" 2>/dev/null)" = "$now" ]; then
        # tested; rerun only if the long suites are still owed and the branch has been quiet
        [ "$(cat "$STATE_DIR/last-eessi.$key" 2>/dev/null)" = "$now" ] && continue
        age=$(( $(date +%s) - $(cut -d' ' -f3 "$STATE_DIR/seen.$key") ))
        [ "$age" -ge $(( QUIET_HOURS * 3600 )) ] || continue
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then echo "would dispatch $repo@$b mattx=${mattx:0:7} tests=${tests:0:7}"; exit 0; fi
    api -X POST -H 'Content-Type: application/json' \
        -d "{\"ref\":\"master\",\"inputs\":{\"mattx_repo\":\"$repo\",\"mattx_ref\":\"$b\"}}" \
        "$FORGEJO_URL/api/v1/repos/$REPO/actions/workflows/mattx-ci.yml/dispatches"
    echo "dispatched $repo@$b mattx=${mattx:0:7} tests=${tests:0:7}"
    exit 0
done <<< "$conf"
