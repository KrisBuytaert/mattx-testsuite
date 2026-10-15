#!/bin/bash
# poll-and-dispatch.sh -- run from a systemd timer on the libvirt host.
# Compares (mattx 1.9-dev tip, testsuite master tip) with the last tested pair
# and dispatches the Forgejo workflow only when either changed. Idle project =
# two ls-remote calls and nothing else.
#
# Env (from /etc/mattx-ci.env, root-only):
#   FORGEJO_URL    e.g. https://forgejo.lab.kribu.be
#   FORGEJO_TOKEN  token allowed to dispatch workflows on vox/mattx-testsuite
#   FORGEJO_CA     CA bundle for the self-signed instance (optional)
set -euo pipefail
STATE="${STATE:-$HOME/last-tested}"   # written by the workflow; run this as forgejo-runner-mattx
MATTX_URL="${MATTX_URL:-https://github.com/brainmatt/mattx}"
MATTX_REF="${MATTX_REF:-refs/heads/1.9-dev}"
TEST_URL="${TEST_URL:-https://github.com/KrisBuytaert/mattx-testsuite}"
REPO="${REPO:-vox/mattx-testsuite}"

mattx=$(git ls-remote "$MATTX_URL" "$MATTX_REF" | cut -f1)
tests=$(git ls-remote "$TEST_URL" refs/heads/master | cut -f1)
[ -n "$mattx" ] && [ -n "$tests" ] || { echo "ls-remote failed" >&2; exit 1; }

now="$mattx $tests"
[ "$(cat "$STATE" 2>/dev/null)" = "$now" ] && exit 0

curl -fsS ${FORGEJO_CA:+--cacert "$FORGEJO_CA"} -X POST \
    -H "Authorization: token $FORGEJO_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"ref\":\"master\",\"inputs\":{\"mattx_sha\":\"$mattx\"}}" \
    "$FORGEJO_URL/api/v1/repos/$REPO/actions/workflows/mattx-ci.yml/dispatches"
# State is written by the workflow itself when the run finishes (pass or fail),
# so a dispatch that never ran is retried on the next tick.
echo "dispatched mattx=${mattx:0:7} tests=${tests:0:7}"
