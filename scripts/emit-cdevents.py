#!/usr/bin/env python3
"""emit-cdevents.py -- turn mattx-test-run/1 JSON (report-to-json.py) into CDEvents and
optionally POST them to a cdviz-collector.

Per run:  testSuiteRun  started + finished
Per case: testCaseRun   started + finished   (outcome pass|fail; the failing line is the reason)
Plus:     testOutput    published            (only with --report-url-base: the transcript on Pages)

Event types and versions follow the CDEvents spec 0.4 testing events
(dev.cdevents.testsuiterun.*.0.2.0, dev.cdevents.testcaserun.*.0.2.0, context.version 0.4.1),
the same shapes cdviz's own demo transformers produce. Event ids are uuid5 of
(subject id, type), so re-sending a run is idempotent on the id.

Usage:
  emit-cdevents.py RUN.json [RUN.json ...] [--ndjson FILE] [--post URL] [--api-key-env VAR]
                   [--report-url-base URL] [--source SRC]

  --ndjson FILE    append the events, one per line (the file published next to the JSON)
  --post URL       POST every event as JSON to URL (cdviz-collector: .../webhook/cdevents),
                   header X-Api-Key from $VAR (default CDVIZ_API_KEY)
  With neither, the events are printed to stdout (a dry run).

Exit status is non-zero if any POST failed.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

CDEVENTS_VERSION = "0.4.1"
NS = uuid.UUID("0b0c3e3e-6d61-4474-8e78-7465737473ee")


def eid(*parts):
    return str(uuid.uuid5(NS, "|".join(parts)))


def env_id(run):
    """one environment per (distro, kernel series): what the dashboards group by"""
    k = run["environment"].get("kernel") or "unknown"
    series = ".".join(k.split("-")[0].split(".")[:2]) if k != "unknown" else k
    return f"{run['distro']}-{series}"


def custom(run):
    m, e = run["mattx"], run["environment"]
    cd = {
        "mattx": {k: v for k, v in {
            "commit": m.get("commit"), "source": m.get("source"), "branch": m.get("branch")}.items() if v},
        "environment": {k: v for k, v in {
            "distro": run["distro"], "kernel": e.get("kernel"), "kernels": e.get("kernels") or None,
            "glibc": next(iter(e.get("glibc", {}).values()), None)}.items() if v},
        "suite": run["suite"],
    }
    if run["ci"].get("run_url"):
        cd["ci"] = {"run_url": run["ci"]["run_url"]}
    return cd


def event(typ, ts, subject_id, subject_type, content, run, source):
    return {
        "context": {
            "version": CDEVENTS_VERSION,
            "id": eid(subject_id, typ),
            "source": source,
            "type": typ,
            "timestamp": ts,
        },
        "subject": {"id": subject_id, "type": subject_type, "content": content},
        "customData": custom(run),
        "customDataContentType": "application/json",
    }


def events_for(run, source, report_url_base=None):
    suite_run = f"{source}/{run['id']}"
    suite_id = f"{source}/suite/{run['suite']}"
    env = {"id": env_id(run)}
    out = []

    suite_ref = {"id": suite_id, "name": run["suite"]}
    out.append(event("dev.cdevents.testsuiterun.started.0.2.0", run["started"], suite_run, "testSuiteRun",
                     {"environment": env, "testSuite": suite_ref}, run, source))

    prev = run["started"]
    for c in run["cases"]:
        cid = f"{suite_run}/{c['id']}"
        t_end = c.get("finished") or run["finished"]
        content = {"environment": env, "testSuiteRun": {"id": suite_run},
                   "testCase": {"id": f"{suite_id}/{c['id']}", "name": c["name"][:200], "type": "integration"}}
        out.append(event("dev.cdevents.testcaserun.started.0.2.0", prev, cid, "testCaseRun", content, run, source))
        fin = dict(content, outcome=c["outcome"])
        if c["outcome"] == "fail":
            fin["reason"] = c["name"][:500]
            fin["severity"] = "high"
        out.append(event("dev.cdevents.testcaserun.finished.0.2.0", t_end, cid, "testCaseRun", fin, run, source))
        if c.get("finished"):
            prev = c["finished"]

    fin = {"environment": env, "testSuite": suite_ref, "outcome": run["outcome"]}
    if run["outcome"] != "pass":
        bad = [c for c in run["cases"] if c["outcome"] == "fail"]
        fin["reason"] = (f"{len(bad)} of {run['counts']['total']} checks failed: " + "; ".join(c["id"] for c in bad)
                         if bad else "run did not finish (no results tally)")[:500]
        fin["severity"] = "high"
    out.append(event("dev.cdevents.testsuiterun.finished.0.2.0", run["finished"], suite_run, "testSuiteRun",
                     fin, run, source))

    if report_url_base:
        url = report_url_base.rstrip("/") + "/" + run["started"][:10] + "/" + run["report"]
        out.append(event("dev.cdevents.testoutput.published.0.2.0", run["finished"], f"{suite_run}/report",
                         "testOutput",
                         {"outputType": "report", "format": "text/plain", "uri": url,
                          "testCaseRun": {"id": suite_run}}, run, source))
    return out


def post(url, key, ev):
    req = urllib.request.Request(url, data=json.dumps(ev).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **({"X-Api-Key": key} if key else {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, ""
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]
    except Exception as e:  # noqa: BLE001 -- network errors: report and carry on
        return 0, str(e)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--ndjson")
    ap.add_argument("--post")
    ap.add_argument("--api-key-env", default="CDVIZ_API_KEY")
    ap.add_argument("--report-url-base")
    ap.add_argument("--source", default="/mattx-testsuite")
    a = ap.parse_args()

    key = os.environ.get(a.api_key_env, "")
    failed = sent = 0
    for path in a.runs:
        with open(path) as f:
            run = json.load(f)
        evs = events_for(run, a.source, a.report_url_base)
        if a.ndjson:
            with open(a.ndjson, "a") as f:
                for e in evs:
                    f.write(json.dumps(e, separators=(",", ":")) + "\n")
        if a.post:
            for e in evs:
                st, body = post(a.post, key, e)
                if 200 <= st < 300:
                    sent += 1
                else:
                    failed += 1
                    print(f"POST {e['context']['type']} {e['subject']['id']}: HTTP {st} {body}", file=sys.stderr)
        elif not a.ndjson:
            for e in evs:
                print(json.dumps(e, indent=2))
    if a.post:
        print(f"cdevents: {sent} sent, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
