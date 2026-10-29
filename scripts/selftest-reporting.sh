#!/bin/bash
# selftest-reporting.sh -- offline check of report-to-json.py + emit-cdevents.py on a fixture report
# (no cluster, no network). Run: scripts/selftest-reporting.sh
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/demo-alma-20261025-100000.txt" <<'EOF'
mattx commit: abc1234def
mattx source: owner/repo@some/branch
almanode1 kernel: 6.12.0-1.el10.x86_64
almanode2 kernel: 6.12.0-1.el10.x86_64
almanode1 glibc: 2.39 glibc-2.39-1
[PASS] demo-1: first thing works
[FAIL] demo-2: second "thing" broke
[PASS] no id on this line
Demo Results: 2 passed, 1 failed
EOF
printf '1793000001.5\t[PASS] demo-1\n1793000007.0\t[FAIL] demo-2\n1793000008.0\t[PASS] no id\n' > "$T/demo-alma-20261025-100000.times"
./report-to-json.py "$T/demo-alma-20261025-100000.txt" >/dev/null
./emit-cdevents.py "$T/demo-alma-20261025-100000.json" --ndjson "$T/ev.ndjson" --report-url-base https://x.example/runs
# two suites of one CI run -> one pipelineRun covering both
cp "$T/demo-alma-20261025-100000.txt" "$T/other-alma-20261025-100500.txt"
sed -i 's/FAIL/PASS/; s/2 passed, 1 failed/3 passed, 0 failed/' "$T/other-alma-20261025-100500.txt"
for n in demo-alma-20261025-100000 other-alma-20261025-100500; do
    CDVIZ_FORGE_URL=https://forge.example GITHUB_SERVER_URL=http://127.0.0.1:3020 GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 GITHUB_RUN_NUMBER=7 GITHUB_WORKFLOW=mattx-ci \
        ./report-to-json.py "$T/$n.txt" >/dev/null
done
./emit-cdevents.py "$T/demo-alma-20261025-100000.json" --siblings "$T" --ndjson "$T/ci.ndjson"
cat > "$T/hang-alma-20260101-000000.txt" <<'EOF'
==============================
mattx commit: abc1234def
mattx source: owner/repo@some/branch
almanode1 kernel: 6.12.0-1.el10
==============================
[PASS] a-1: first
Connection timed out during banner exchange
==============================
mattx commit: unknown
mattx source: unknown
almanode1 kernel: unknown
==============================
[FAIL] b-1: after the hang
EOF
./report-to-json.py "$T/hang-alma-20260101-000000.txt" >/dev/null
python3 -I - "$T" <<'PY'
import json, sys
t = sys.argv[1]
r = json.load(open(f"{t}/demo-alma-20261025-100000.json"))
assert r["schema"] == "mattx-test-run/1" and r["outcome"] == "fail", r["outcome"]
assert r["counts"] == {"total": 3, "passed": 2, "failed": 1}, r["counts"]
assert r["mattx"]["branch"] == "some/branch" and r["environment"]["kernel"].startswith("6.12"), r
assert [c["id"] for c in r["cases"]] == ["demo-1", "demo-2", "no-id-on-this-line"], r["cases"]
assert r["cases"][1]["duration_s"] == 5.5, r["cases"][1]
ev = [json.loads(l) for l in open(f"{t}/ev.ndjson")]
types = [e["context"]["type"].split(".", 2)[2] for e in ev]
assert types.count("testcaserun.finished.0.2.0") == 3 and types.count("testsuiterun.finished.0.2.0") == 1, types
assert len({e["context"]["id"] for e in ev}) == len(ev), "event ids must be unique"
sf = next(e for e in ev if e["context"]["type"].startswith("dev.cdevents.testsuiterun.finished"))
assert sf["subject"]["content"]["outcome"] == "fail" and "demo-2" in sf["subject"]["content"]["reason"]
ci = [json.loads(l) for l in open(f"{t}/ci.ndjson")]
pf = [e for e in ci if e["context"]["type"].startswith("dev.cdevents.pipelinerun.finished")]
ps = [e for e in ci if e["context"]["type"].startswith("dev.cdevents.pipelinerun.started")]
assert len(pf) == 1 and len(ps) == 1, (len(pf), len(ps))
assert pf[0]["subject"]["id"].endswith("/ci/42") and pf[0]["subject"]["content"]["outcome"] == "failure", pf[0]
assert pf[0]["subject"]["content"]["pipelineName"] == "mattx-ci" and "demo-alma" in pf[0]["subject"]["content"]["errors"]
assert pf[0]["subject"]["content"]["url"] == "https://forge.example/o/r/actions/runs/7"
sr = next(e for e in ci if e["context"]["type"].startswith("dev.cdevents.testsuiterun.started"))
assert sr["customData"]["links"][0]["subject"]["id"] == pf[0]["subject"]["id"], sr["customData"]
# a node that stops answering mid-run makes the later banners say "unknown": the first known values stay
j = json.load(open(f"{t}/hang-alma-20260101-000000.json"))
assert j["mattx"]["commit"] == "abc1234def" and j["mattx"]["branch"] == "some/branch", j["mattx"]
assert j["environment"]["kernel"] == "6.12.0-1.el10" and j["node_unreachable_lines"] == 1, j["environment"]
print("selftest-reporting: ok (%d events)" % len(ev))
PY
