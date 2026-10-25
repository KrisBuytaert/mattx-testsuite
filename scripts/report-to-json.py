#!/usr/bin/env python3
"""report-to-json.py -- turn a test transcript (reports/<label>-<distro>-<ts>.txt)
into a machine-readable JSON record, "mattx-test-run/1".

The JSON is what everything downstream (the Pages site, emit-cdevents.py and so
cdviz) consumes, so the transcript parsing lives in one place: report-table.py's
parse_report() for the banner and the [PASS]/[FAIL] lines, plus, if present, the
<report>.times sidecar that auto_report_wrap() writes (epoch<TAB>[PASS] text per
check) for per-check timestamps and durations.

One report is one *suite run*; every [PASS]/[FAIL] line is one *case run*.
A case id is the text before the first ':' of the line ("mpi-3: counting
continued ..." -> id "mpi-3"), else a slug of the message.

Usage:
  report-to-json.py REPORT.txt [-o REPORT.json]     one run (default: next to the report)
  report-to-json.py --all [DIR] [-o run-summary.json]   aggregate of every report in DIR
                                                       (default reports/), newest first
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone

SCHEMA = "mattx-test-run/1"

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("report_table", os.path.join(_here, "report-table.py"))
report_table = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(report_table)

# "mpi-3: counting ..." and "admin-27 (nonexistent pid): ..." both give the id (mpi-3, admin-27)
CASE_ID_RE = re.compile(r"^([A-Za-z][\w.+]*-\d+[a-z]?)(?:\s*:\s*|\s+)(.*)$|^([A-Za-z0-9][\w.+-]*):\s+(.*)$")
GLIBC_RE = re.compile(r"^(\S+)\s+glibc:\s*(\S+)")


def slug(text, n=48):
    s = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower()
    return s[:n].rstrip("-") or "case"


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_times(path):
    """epoch per check, in file order, from the sidecar; [] if there is none."""
    side = path[:-4] + ".times" if path.endswith(".txt") else path + ".times"
    out = []
    try:
        with open(side) as f:
            for line in f:
                head = line.split("\t", 1)[0]
                try:
                    out.append(float(head))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def read_glibc(path):
    out = {}
    with open(path, errors="replace") as f:
        for line in f:
            m = GLIBC_RE.match(line.rstrip("\n"))
            if m:
                out[m.group(1)] = m.group(2)
    return out


def convert(path):
    r = report_table.parse_report(path)
    base = os.path.basename(path)
    nm = report_table.NAME_RE.match(base)
    if nm:
        start = datetime.strptime(nm.group("ts"), "%Y%m%d-%H%M%S").timestamp()  # local time, as written
    else:
        start = r["mtime"]
    end = max(r["mtime"], start)
    # a report touched later (copied, restored) says nothing about when the run ended: no run takes
    # half a day, so past that the end is unknown and the run is dated at its start
    dur_known = end - start <= 12 * 3600
    if not dur_known:
        end = start
    times = read_times(path)
    n = len(r["assertions"])
    timed = len(times) == n and n > 0

    cases = []
    prev = start
    for i, (status, msg) in enumerate(r["assertions"]):
        m = CASE_ID_RE.match(msg)
        cid, name = ((m.group(1) or m.group(3)), (m.group(2) or m.group(4))) if m else (slug(msg), msg)
        finished = times[i] if timed else None
        dur = round(max(finished - prev, 0.0), 1) if timed else None
        if timed:
            prev = finished
        cases.append({
            "id": cid,
            "name": name,
            "outcome": "pass" if status == "PASS" else "fail",
            "finished": iso(finished) if timed else None,
            "duration_s": dur,
        })

    fails = sum(1 for c in cases if c["outcome"] == "fail")
    if fails:
        outcome = "fail"
    elif not r["completed"]:
        outcome = "error"      # killed / crashed before its own "Results:" tally, nothing failed so far
    else:
        outcome = "pass"

    source = r["source"]
    branch = source.split("@", 1)[1] if source and "@" in source else None
    kernels = r["kernels"]
    uniq = sorted(set(kernels.values()))
    server = os.environ.get("GITHUB_SERVER_URL")
    repo = os.environ.get("GITHUB_REPOSITORY")
    run_id = os.environ.get("GITHUB_RUN_ID")
    ci_url = f"{server}/{repo}/actions/runs/{run_id}" if server and repo and run_id else None

    return {
        "schema": SCHEMA,
        "id": f"{r['label']}-{r['distro']}-{nm.group('ts')}" if nm else slug(base),
        "suite": r["label"],
        "distro": r["distro"],
        "report": base,
        "started": iso(start),
        "finished": iso(end),
        "duration_s": round(end - start, 1) if dur_known else None,
        "outcome": outcome,
        "completed": r["completed"],
        "counts": {"total": len(cases), "passed": len(cases) - fails, "failed": fails},
        "mattx": {
            "commit": r["commit"],
            "source": source,
            "branch": branch,
        },
        "environment": {
            "kernel": uniq[0] if len(uniq) == 1 else None,
            "kernels": kernels,
            "glibc": read_glibc(path),
        },
        "ci": {"run_url": ci_url, "run_id": run_id, "run_number": os.environ.get("GITHUB_RUN_NUMBER"),
               "workflow": os.environ.get("GITHUB_WORKFLOW")} if ci_url else {"run_url": None},
        "cases": cases,
    }


def write_json(obj, out):
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp, out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", nargs="?", help="report .txt, or with --all a reports directory")
    ap.add_argument("-o", "--out")
    ap.add_argument("--all", action="store_true", help="aggregate every report in the directory")
    a = ap.parse_args()

    if a.all:
        d = a.report or os.path.join(os.path.dirname(_here), "reports")
        files = sorted(glob.glob(os.path.join(d, "*.txt")))
        runs = [convert(f) for f in files]
        runs.sort(key=lambda x: x["started"], reverse=True)
        out = a.out or os.path.join(d, "run-summary.json")
        write_json({"schema": SCHEMA + "-index", "generated": iso(datetime.now().timestamp()),
                    "runs": [{k: v for k, v in x.items() if k != "cases"} for x in runs]}, out)
        print(f"{out}: {len(runs)} runs")
        return 0

    if not a.report:
        ap.error("a report file is required")
    out = a.out or re.sub(r"\.txt$", "", a.report) + ".json"
    write_json(convert(a.report), out)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
