#!/bin/bash
# notify-telegram.sh <branch> <functional-result> <eessi-result> <run-number>
# Final step of mattx-ci: sends one Telegram message with the outcome and the
# per-suite test results of THIS run (reports newer than $H/.run-start).
# Forgejo's own webhook only covers failure/recover; this adds success and a summary.
# Needs $HOME/telegram.env (root-provisioned, 0600) with BOT_TOKEN= and CHAT_ID=.
set -u
branch="${1:-?}"; fres="${2:-?}"; eres="${3:-?}"; run="${4:-?}"
ENV_FILE="${TELEGRAM_ENV:-$HOME/telegram.env}"
[ -r "$ENV_FILE" ] || { echo "no $ENV_FILE, skipping telegram"; exit 0; }
# shellcheck disable=SC1090
. "$ENV_FILE"
H="${H:-$HOME/harness}"
sha=$(git -C "$HOME/mattx-src" rev-parse --short HEAD 2>/dev/null || echo "?")

fails=0; lines=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    label=$(basename "$f" | sed -E 's/-(alma|deb|ubu|fed)-[0-9]{8}-[0-9]{6}\.txt$/ (\1)/; s/ \(alma\)$//')
    res=$(grep -E 'Results:' "$f" | tail -1 | sed -E 's/.*Results:[[:space:]]*//')
    if [ -z "$res" ]; then res="no result line (incomplete)"; fails=$((fails+1))
    else m=$(echo "$res" | sed -nE 's/.*, ([0-9]+) failed.*/\1/p'); [ "${m:-0}" -gt 0 ] && fails=$((fails+1)); fi
    lines="$lines
  $label: $res"
done < <(find "$H/reports" \( -name '*-alma-*.txt' -o -name '*-deb-*.txt' -o -name '*-ubu-*.txt' -o -name '*-fed-*.txt' \) -newer "$H/.run-start" 2>/dev/null | sort)

if [ "$fres" != success ] || { [ "$eres" != success ] && [ "$eres" != skipped ]; }; then icon="FAILED (infrastructure)"
elif [ "$fails" -gt 0 ]; then icon="done, $fails suite(s) with failures"
else icon="all suites passed"; fi

msg="mattx-ci $branch @ $sha: $icon
functional=$fres eessi=$eres$lines
https://forgejo.lab.kribu.be/vox/mattx-testsuite/actions/runs/$run
Page: https://krisbuytaert.be/mattx-test-reports/"
curl -fsS -o /dev/null --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$msg" \
    "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" && echo "telegram sent" || echo "telegram failed" >&2
exit 0
