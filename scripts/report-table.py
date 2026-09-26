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
# Printed by every test script's own final tally line ("Results: N passed, M
# failed", "DSM Results: ...", "Stale-Link Results: ..."). Its absence means
# the run was killed/crashed/interrupted before finishing -- distinct from a
# genuinely clean pass, which must not be reported the same way.
RESULTS_RE = re.compile(r"Results:\s*\d+\s*passed,\s*\d+\s*failed")
# label-distro-YYYYMMDD-HHMMSS.txt
NAME_RE = re.compile(r"^(?P<label>.+)-(?P<distro>alma|deb|ubu)-(?P<ts>\d{8}-\d{6})\.txt$")


def parse_report(path):
    commit = None
    kernels = {}
    assertions = []  # (status, message) in file order
    completed = False
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
                continue
            if RESULTS_RE.search(line):
                completed = True
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
        "completed": completed,
    }


def kernel_summary(kernels):
    if not kernels:
        return "unknown"
    unique = sorted(set(kernels.values()))
    if len(unique) == 1:
        return unique[0]
    # different kernels across nodes -- show which node has which
    return ", ".join(f"{n}={v}" for n, v in sorted(kernels.items()))


def test_summary(assertions, completed):
    """Returns (kind, header, fails) -- kind is 'pass', 'fail', or 'incomplete',
    used by the renderers to pick a color independently of the fails list."""
    total = len(assertions)
    fails = [msg for status, msg in assertions if status == "FAIL"]
    passed = total - len(fails)
    if not completed:
        prefix = f"{passed} passed, {len(fails)} failed so far" if total else "no checks reached"
        return "incomplete", f"⚠️ incomplete run (stopped early) — {prefix}", fails
    if not fails:
        header = f"✅ all {total} passed" if total else "(no assertions found)"
        return "pass", header, []
    return "fail", f"❌ {len(fails)} failed, {passed} passed", fails


def sort_key(r):
    return (kernel_summary(r["kernels"]), r["commit"] or "", r["date"])


def render_markdown(reports):
    out = ["## mattx test run summary\n"]
    out.append("| Kernel | mattx commit | Label | Date | Result |")
    out.append("|---|---|---|---|---|")
    for r in sorted(reports, key=sort_key):
        kernel = kernel_summary(r["kernels"])
        commit = (r["commit"] or "unknown")[:12]
        _kind, header, fails = test_summary(r["assertions"], r["completed"])
        result = f"{header} — FAIL: {'; '.join(fails)}" if fails else header
        out.append(f"| {kernel} | {commit} | {r['label']} ({r['distro']}) | {r['date']} | {result} |")
    return "\n".join(out) + "\n"


HTML_PAGE_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>mattx test run summary</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2em; color: #1a1a1a; }
  h1 { font-size: 1.3em; }
  .controls { margin-bottom: 1em; display: flex; gap: 2em; align-items: flex-start; flex-wrap: wrap; }
  .controls fieldset { border: 1px solid #ccc; border-radius: 6px; padding: 0.4em 1em; }
  .controls legend { font-size: 0.85em; color: #555; padding: 0 0.4em; }
  .controls label { display: block; font-size: 0.9em; margin: 2px 0; white-space: nowrap; }
  #search { padding: 4px 8px; font-size: 0.9em; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; vertical-align: top; font-size: 0.9em; }
  th { background: #f5f5f5; cursor: pointer; user-select: none; white-space: nowrap; }
  th.sorted-asc::after { content: " \\25B2"; }
  th.sorted-desc::after { content: " \\25BC"; }
  ul { margin: 4px 0 0 0; padding-left: 1.2em; }
  tr.row-hidden { display: none; }
  #count { font-size: 0.85em; color: #555; margin-bottom: 0.5em; }
</style>
</head>
<body>
<h1>mattx test run summary</h1>
<div class="controls">
  <fieldset>
    <legend>Run type</legend>
    __LABEL_CHECKBOXES__
  </fieldset>
  <fieldset>
    <legend>Result</legend>
    <label><input type="checkbox" class="status-filter" value="pass" checked> Pass</label>
    <label><input type="checkbox" class="status-filter" value="fail" checked> Fail</label>
    <label><input type="checkbox" class="status-filter" value="incomplete" checked> Incomplete</label>
  </fieldset>
  <fieldset>
    <legend>Search (kernel / commit)</legend>
    <input id="search" type="text" placeholder="filter...">
  </fieldset>
</div>
<div id="count"></div>
<table id="summary">
<thead>
<tr>
  <th data-key="kernel">Kernel</th>
  <th data-key="commit">mattx commit</th>
  <th data-key="label">Label</th>
  <th data-key="date">Date</th>
  <th data-key="status">Result</th>
</tr>
</thead>
<tbody>
__ROWS__
</tbody>
</table>
<script>
(function() {
  var table = document.getElementById('summary');
  var tbody = table.tBodies[0];
  var headers = Array.prototype.slice.call(table.querySelectorAll('th[data-key]'));

  function getRows() { return Array.prototype.slice.call(tbody.rows); }

  function applySort(key, dir) {
    var rows = getRows();
    rows.sort(function(a, b) {
      var av = a.getAttribute('data-' + key) || '';
      var bv = b.getAttribute('data-' + key) || '';
      if (av < bv) return -1 * dir;
      if (av > bv) return 1 * dir;
      return 0;
    });
    rows.forEach(function(r) { tbody.appendChild(r); });
    headers.forEach(function(h) { h.classList.remove('sorted-asc', 'sorted-desc'); });
    headers.filter(function(h) { return h.getAttribute('data-key') === key; })
      .forEach(function(h) { h.classList.add(dir === 1 ? 'sorted-asc' : 'sorted-desc'); });
  }

  var sortState = { key: null, dir: 1 };
  headers.forEach(function(h) {
    h.addEventListener('click', function() {
      var key = h.getAttribute('data-key');
      sortState.dir = (sortState.key === key) ? -sortState.dir : -1;
      sortState.key = key;
      applySort(key, sortState.dir);
    });
  });

  // Default view: most recent run first.
  sortState.key = 'date'; sortState.dir = -1;
  applySort('date', -1);

  function applyFilters() {
    var activeLabels = Array.prototype.map.call(
      document.querySelectorAll('.label-filter:checked'), function(cb) { return cb.value; }
    );
    var activeStatuses = Array.prototype.map.call(
      document.querySelectorAll('.status-filter:checked'), function(cb) { return cb.value; }
    );
    var search = document.getElementById('search').value.trim().toLowerCase();
    var visible = 0;
    getRows().forEach(function(row) {
      var label = row.getAttribute('data-label');
      var status = row.getAttribute('data-status');
      var haystack = (row.getAttribute('data-kernel') + ' ' + row.getAttribute('data-commit')).toLowerCase();
      var show = activeLabels.indexOf(label) !== -1 &&
                 activeStatuses.indexOf(status) !== -1 &&
                 (search === '' || haystack.indexOf(search) !== -1);
      row.classList.toggle('row-hidden', !show);
      if (show) visible++;
    });
    document.getElementById('count').textContent = visible + ' / ' + getRows().length + ' runs shown';
  }

  Array.prototype.forEach.call(document.querySelectorAll('.label-filter, .status-filter'), function(cb) {
    cb.addEventListener('change', applyFilters);
  });
  document.getElementById('search').addEventListener('input', applyFilters);

  applyFilters();
})();
</script>
</body>
</html>
"""


def render_html(reports):
    """Self-contained, sortable, filterable page -- no external dependencies,
    works fine opened directly via file://. Default view sorts by date,
    most recent run first; click any column header to re-sort by it."""
    rows = []
    labels = sorted({r["label"] for r in reports})
    for r in sorted(reports, key=sort_key):
        kernel = escape(kernel_summary(r["kernels"]))
        commit = escape((r["commit"] or "unknown")[:12])
        label_raw = escape(r["label"])
        label_full = escape(f"{r['label']} ({r['distro']})")
        date = escape(r["date"])
        kind, header, fails = test_summary(r["assertions"], r["completed"])
        bg = {
            "pass": "#e6ffed",
            "fail": "#ffeef0",
            "incomplete": "#fff8e1",
        }[kind]
        if fails:
            fail_items = "".join(f"<li>{escape(f)}</li>" for f in fails)
            result_html = f"{escape(header)}<ul>{fail_items}</ul>"
        else:
            result_html = escape(header)
        rows.append(
            f'<tr data-kernel="{kernel}" data-commit="{commit}" data-label="{label_raw}" '
            f'data-date="{date}" data-status="{kind}" style="background:{bg}">'
            f"<td>{kernel}</td><td>{commit}</td><td>{label_full}</td><td>{date}</td>"
            f"<td>{result_html}</td></tr>"
        )

    label_checkboxes = "\n    ".join(
        f'<label><input type="checkbox" class="label-filter" value="{escape(l)}" checked> {escape(l)}</label>'
        for l in labels
    )

    page = HTML_PAGE_TEMPLATE.replace("__LABEL_CHECKBOXES__", label_checkboxes)
    page = page.replace("__ROWS__", "\n".join(rows))
    return page


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
