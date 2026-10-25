#!/bin/bash
# send-cdevents.sh -- POST the CDEvents of every report not sent yet to a cdviz-collector.
#
# Env:  CDVIZ_URL      collector endpoint, e.g. https://cdviz.example/webhook/cdevents (unset = do nothing)
#       CDVIZ_API_KEY  value for the X-Api-Key header (never printed)
#       CDVIZ_REPORT_URL_BASE  Pages base of the transcripts (default https://krisbuytaert.be/mattx-test-reports/runs)
#       CDVIZ_BACKFILL=1       on the very first run, also send the reports that already exist
#
# State: reports/.cdevents-sent (one report name per line). Without that file the existing reports are
# only *marked* as sent, so switching this on does not replay months of history unless asked to.
# Only runs that finished their own tally ("completed") or have a failed check are sent; a run still
# being written is picked up next time. Failure to reach the collector never fails the caller.
set -uo pipefail
cd "$(dirname "$0")/.."

[ -n "${CDVIZ_URL:-}" ] || { echo "[cdevents] CDVIZ_URL not set -- skipping"; exit 0; }
export CDVIZ_API_KEY="${CDVIZ_API_KEY:-}"
BASE="${CDVIZ_REPORT_URL_BASE:-https://krisbuytaert.be/mattx-test-reports/runs}"
STATE=reports/.cdevents-sent

first=0; [ -e "$STATE" ] || { first=1; : > "$STATE"; }
sent=0; failed=0
for txt in reports/*-alma-*.txt reports/*-deb-*.txt reports/*-ubu-*.txt reports/*-fed-*.txt; do
    [ -e "$txt" ] || continue
    name=$(basename "$txt" .txt)
    grep -qxF "$name" "$STATE" && continue
    if [ "$first" = 1 ] && [ "${CDVIZ_BACKFILL:-0}" != 1 ]; then echo "$name" >> "$STATE"; continue; fi
    json="${txt%.txt}.json"
    [ -e "$json" ] && [ ! "$txt" -nt "$json" ] || scripts/report-to-json.py "$txt" >/dev/null || continue
    # not finished and nothing failed yet: probably still running, leave it for the next call
    python3 -I - "$json" <<'PY' || continue
import json, sys
r = json.load(open(sys.argv[1]))
sys.exit(0 if r["completed"] or r["counts"]["failed"] else 1)
PY
    if scripts/emit-cdevents.py "$json" --post "$CDVIZ_URL" --report-url-base "$BASE" --siblings reports >/dev/null; then
        echo "$name" >> "$STATE"; sent=$((sent+1))
    else
        failed=$((failed+1))
    fi
done
echo "[cdevents] $sent runs sent, $failed failed$([ "$first" = 1 ] && [ "${CDVIZ_BACKFILL:-0}" != 1 ] && echo ' (first run: existing reports marked as sent, not replayed)')"
exit 0
