#!/bin/bash
# publish-pages.sh -- publish the report-table output to the gh-pages repo.
#
# Builds reports/run-summary.{md,html} via report-table.py and run-summary.json via report-to-json.py, scrubs
# internal paths/IPs (hostnames and kernel versions stay), and pushes to the
# gh-pages branch of KrisBuytaert/mattx-test-reports with a write-only deploy
# key. Layout on the page: index.html = summary table of ALL reports;
# runs/<YYYY-MM-DD>/ = scrubbed raw reports, dated from each filename.
#
# Usage: scripts/publish-pages.sh [--dry-run]   (dry run: stage, don't push)
# Env:   PAGES_REPO (default git@github.com:KrisBuytaert/mattx-test-reports.git)
#        PAGES_KEY  (default keys/pages_deploy)
set -euo pipefail
cd "$(dirname "$0")/.."

PAGES_REPO="${PAGES_REPO:-git@github.com:KrisBuytaert/mattx-test-reports.git}"
PAGES_KEY="${PAGES_KEY:-$PWD/keys/pages_deploy}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

scrub() {
    sed -E \
        -e 's#/home/[A-Za-z0-9_.-]+/#/home/USER/#g' \
        -e 's#\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b#x.x.x.x#g' \
        -e 's#(token|password|secret)[=: ]+[^ ]+#\1=REDACTED#Ig'
}

make report-table >/dev/null
# machine-readable twins: <report>.json per run (rebuilt when missing or older than the transcript)
# and the run-summary.json index; cdviz gets the same data as CDEvents (send-cdevents.sh).
for f in reports/*-alma-*.txt reports/*-deb-*.txt reports/*-ubu-*.txt reports/*-fed-*.txt; do
    [ -e "$f" ] || continue
    [ ! "$f" -nt "${f%.txt}.json" ] && [ -e "${f%.txt}.json" ] || scripts/report-to-json.py "$f" >/dev/null || true
done
scripts/report-to-json.py --all reports -o reports/run-summary.json >/dev/null
scripts/send-cdevents.sh || true

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_SSH_COMMAND="ssh -i $PAGES_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
# The lab link to github.com is not always up (run 259: "ssh: connect to host github.com port 22: Connection
# timed out" failed a job whose suites had all run). Retry, and alternate with ssh over port 443
# (ssh.github.com). A publish that still fails exits 75 with NOT PUBLISHED: the reports stay in reports/ and go
# out with the next publish, which republishes everything. Callers treat 75 as "not published", not as a test failure.
PAGES_REPO_443="${PAGES_REPO_443:-ssh://git@ssh.github.com:443/${PAGES_REPO#*:}}"
with_retry() {          # with_retry <what> <cmd...>: try the normal URL and the 443 one alternately
    local what="$1"; shift
    local i
    for i in 1 2 3 4 5 6; do
        if [ $((i % 2)) -eq 1 ]; then url="$PAGES_REPO"; else url="$PAGES_REPO_443"; fi
        "$@" && return 0
        echo "[publish] $what failed (attempt $i/6, $url); retrying in $((i * ${PUBLISH_RETRY_SLEEP:-10})) s" >&2
        sleep $((i * ${PUBLISH_RETRY_SLEEP:-10}))
    done
    return 1
}
not_published() { echo "NOT PUBLISHED: github.com unreachable; $1. The reports stay in reports/ and are published by the next run." >&2; exit 75; }
_clone() { rm -rf "$work/site"; git clone -q --branch gh-pages --depth 1 "$url" "$work/site"; }
with_retry "clone" _clone || not_published "clone failed"

run="runs"   # per-report subdirs below, dated from each filename

scrub < reports/run-summary.html > "$work/site/index.html"
mkdir -p "$work/site/$run"
scrub < reports/run-summary.md > "$work/site/$run/run-summary.md"
scrub < reports/run-summary.json > "$work/site/run-summary.json"
for f in reports/*-alma-*.txt reports/*-deb-*.txt reports/*-ubu-*.txt reports/*-fed-*.txt; do
    [ -e "$f" ] || continue
    ts=$(basename "$f" .txt | grep -oE '[0-9]{8}-[0-9]{6}$' | cut -c1-8)
    d="$work/site/$run/${ts:0:4}-${ts:4:2}-${ts:6:2}"
    mkdir -p "$d"
    scrub < "$f" > "$d/$(basename "$f")"
    [ -e "${f%.txt}.json" ] && scrub < "${f%.txt}.json" > "$d/$(basename "${f%.txt}.json")"
    nd="$d/$(basename "${f%.txt}.cdevents.ndjson")"; rm -f "$nd"
    scripts/emit-cdevents.py "${f%.txt}.json" --report-url-base "${CDVIZ_REPORT_URL_BASE:-https://krisbuytaert.be/mattx-test-reports/runs}" \
        --ndjson "$nd" 2>/dev/null || rm -f "$nd"
done
touch "$work/site/.nojekyll"

cd "$work/site"
git add -A
if git diff --cached --quiet; then echo "nothing new to publish"; exit 0; fi
if [ "$DRY" = 1 ]; then
    git diff --cached --stat | tail -5
    dry="${TMPDIR:-/tmp}/pages-dry"; rm -rf "$dry"; mkdir -p "$dry"
    cp -r "$work/site/." "$dry/"
    echo "dry run: staged copy in $dry"; exit 0
fi
git -c user.name="mattx-testsuite" -c user.email="noreply@percona.com" commit -q -m "Publish reports $(date -u +%Y-%m-%dT%H:%MZ)"
_push() { git push -q "$url" gh-pages; }
with_retry "push" _push || not_published "push failed"
echo "published"
