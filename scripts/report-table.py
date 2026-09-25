#!/usr/bin/env python3
"""report-table.py -- build a per-run summary table from test/reports/*.txt
transcripts, keyed by kernel version and mattx commit.

One row per report (one test run), sorted by kernel version, then mattx
commit, then date -- so runs against the same environment sit together and
you can see at a glance whether a given (kernel, commit) combination is
solid or flaky across repeated runs. Columns: kernel(s), mattx commit,
date, and a compact pass/fail test summary.

Reports from before the version banner existed (see CHANGELOG.md, added to
auto_report_wrap() in lib.sh) show "unknown" for kernel/commit rather than
being dropped -- they still carry real pass/fail evidence.

Usage:
  scripts/report-table.py [--format md|html|both] [--out FILE] [reports...]

With no report files given, scans test/reports/*.txt (non-recursive --
reports moved into a dated archive subdirectory are intentionally excluded
unless passed explicitly, e.g. reports/2026-09/*.txt).
"""
import argparse
import glob
import os
import re
import sys
from datetime import datetime
from html import escape

TAG_RE = re.compile(r"^\[(PASS|FAIL)\]\s+(.*)$")
COMMIT_RE = re.compile(r"^mattx commit:\s*(\S+)\s*$")
KERNEL_RE = re.compile(r"^(\S+)\s+kernel:\s*(\S+)\s*$")
# label-distro-YYYYMMDD-HHMMSS.txt
NAME_RE = re.compile(r"^(?P<label>.+)-(?P<distro>alma|deb|ubu)-(?P<ts>\d{8}-\d{6})\.txt$")


def parse_report(path):
    commit = None
    kernels = {}
    assertions = []  # (status, message) in file order
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = COMMIT_RE.match(line)
            if m:
                commit = m.group(1)
                continue
            m = KERNEL_RE.match(line)
            if m:
                kernels[m.group(1)] = m.group(2)
                continue
            m = TAG_RE.match(line)
            if m:
                assertions.append((m.group(1), m.group(2)))
    basename = os.path.basename(path)
    m = NAME_RE.match(basename)
    label = m.group("label") if m else basename
    distro = m.group("distro") if m else "?"
    ts_raw = m.group("ts") if m else None
    if ts_raw:
        date_str = datetime.strptime(ts_raw, "%Y%m%d-%H%M%S").strftime("%Y-%m-%d %H:%M")
    else:
        date_str = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d %H:%M")
    mtime = os.path.getmtime(path)
    return {
        "path": path,
        "label": label,
        "distro": distro,
        "date": date_str,
        "mtime": mtime,
        "commit": commit,
        "kernels": kernels,
        "assertions": assertions,
    }


def kernel_summary(kernels):
    if not kernels:
        return "unknown"
    unique = sorted(set(kernels.values()))
    if len(unique) == 1:
        return unique[0]
    # different kernels across nodes -- show which node has which
    return ", ".join(f"{n}={v}" for n, v in sorted(kernels.items()))


def test_summary(assertions):
    total = len(assertions)
    fails = [msg for status, msg in assertions if status == "FAIL"]
    passed = total - len(fails)
    if not fails:
        return f"✅ all {total} passed" if total else "(no assertions found)"
    header = f"❌ {len(fails)} failed, {passed} passed"
    return header, fails


def sort_key(r):
    return (kernel_summary(r["kernels"]), r["commit"] or "", r["date"])


def render_markdown(reports):
    out = ["## mattx test run summary\n"]
    out.append("| Kernel | mattx commit | Label | Date | Result |")
    out.append("|---|---|---|---|---|")
    for r in sorted(reports, key=sort_key):
        kernel = kernel_summary(r["kernels"])
        commit = (r["commit"] or "unknown")[:12]
        summary = test_summary(r["assertions"])
        if isinstance(summary, tuple):
            header, fails = summary
            fail_list = "; ".join(fails)
            result = f"{header} — FAIL: {fail_list}"
        else:
            result = summary
        out.append(f"| {kernel} | {commit} | {r['label']} ({r['distro']}) | {r['date']} | {result} |")
    return "\n".join(out) + "\n"


def render_html(reports):
    out = ['<table border="1" cellpadding="4" cellspacing="0">']
    out.append("<tr><th>Kernel</th><th>mattx commit</th><th>Label</th><th>Date</th><th>Result</th></tr>")
    for r in sorted(reports, key=sort_key):
        kernel = escape(kernel_summary(r["kernels"]))
        commit = escape((r["commit"] or "unknown")[:12])
        label = escape(f"{r['label']} ({r['distro']})")
        date = escape(r["date"])
        summary = test_summary(r["assertions"])
        if isinstance(summary, tuple):
            header, fails = summary
            bg = ' style="background:#ffeef0"'
            fail_items = "".join(f"<li>{escape(f)}</li>" for f in fails)
            result = f"{escape(header)}<ul>{fail_items}</ul>"
        else:
            bg = ' style="background:#e6ffed"'
            result = escape(summary)
        out.append(
            f"<tr><td>{kernel}</td><td>{commit}</td><td>{label}</td><td>{date}</td>"
            f"<td{bg}>{result}</td></tr>"
        )
    out.append("</table>")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", nargs="*", help="report .txt files (default: reports/*.txt)")
    ap.add_argument("--format", choices=["md", "html", "both"], default="md")
    ap.add_argument("--out", help="write to this file instead of stdout (with --format both, used as a base name)")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_dir = os.path.join(script_dir, "..", "reports")
    paths = args.reports or sorted(glob.glob(os.path.join(default_dir, "*.txt")))
    if not paths:
        print("no report files found", file=sys.stderr)
        sys.exit(1)

    reports = [parse_report(p) for p in paths]

    def write(text, suffix):
        if args.out:
            base = args.out
            if args.format == "both":
                root, _ = os.path.splitext(base)
                base = f"{root}.{suffix}"
            with open(base, "w") as f:
                f.write(text)
            print(f"wrote {base}", file=sys.stderr)
        else:
            print(text)

    if args.format in ("md", "both"):
        write(render_markdown(reports), "md")
    if args.format in ("html", "both"):
        write(render_html(reports), "html")


if __name__ == "__main__":
    main()
