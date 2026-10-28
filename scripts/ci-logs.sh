#!/bin/bash
# ci-logs.sh <run-number|latest> [outdir] -- download the job logs of a Forgejo CI run (Forgejo >= 17 API).
# The run number is the one the UI shows (index_in_repo); the API's own run id is a different counter.
# Token: $FORGEJO_TOKEN, else TF_VAR_forgejo_api_token from /home/src/tofu-forgejo/.env. Never printed.
set -euo pipefail
U="${FORGEJO_URL:-https://forgejo.lab.kribu.be}"; R="${REPO:-vox/mattx-testsuite}"
[ -n "${FORGEJO_TOKEN:-}" ] || FORGEJO_TOKEN=$(. /home/src/tofu-forgejo/.env >/dev/null 2>&1; echo "$TF_VAR_forgejo_api_token")
api() { curl -fsSk -H "Authorization: token $FORGEJO_TOKEN" "$@"; }
want="${1:-latest}"; out="${2:-ci-logs-$want}"
id=$(api "$U/api/v1/repos/$R/actions/runs?limit=50" | python3 -c '
import json,sys
want=sys.argv[1]; runs=json.load(sys.stdin)["workflow_runs"]
for r in runs:
    if want=="latest" or str(r["index_in_repo"])==want: print(r["id"]); break' "$want")
[ -n "$id" ] || { echo "run $want not found" >&2; exit 1; }
mkdir -p "$out" && api -o "$out/logs.zip" "$U/api/v1/repos/$R/actions/runs/$id/logs" && unzip -qo "$out/logs.zip" -d "$out" && rm "$out/logs.zip"
echo "logs of run $want (api id $id) in $out/"; ls "$out"
