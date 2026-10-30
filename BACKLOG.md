# Backlog

Parked work, not scheduled. Current focus is MattX bugfixing.

## Monitoring of the test nodes (puppetry)
- Enrol the almanodes (later deb/ubu/fed) in puppetry: agent + `role::mattx_node` + `profile_base`
  (node_exporter via package, Prometheus discovery through PuppetDB). Open question: enrol with the
  openvox CA, or agentless node_exporter + static scrape job.
- Textfile-collector metrics: mattx.ko loads since boot, `execmem: unable` lines, new kdumps in
  /var/crash, mattx.service active.
- Perses panel per node + alerts (execmem errors > 0, kdump count rose).
- Then replace the load-count threshold in `scripts/node-health.sh` with the real signal
  (run 144: ENOMEM at 23 loads, run 120 at 46).

## CI / reporting
- Record a failed deploy (e.g. insmod ENOMEM) as a failed entry on the Pages site and in cdviz; today
  the run produces no reports and is only visible in the Telegram/Signal summary.
- Resend or correct run 128's CDEvents in cdviz (unknown commit/branch); check whether the collector
  ignores repeated event ids first.
- `.forgejo/workflows/mattx-ci.yml` input defaults still say 1.9-dev.

## EESSI failures to re-check on a clean cluster
- openfoam-3 / tensorflow-3: "not actually running on almanode2 after migration".
- espresso-3, qe-3/qe-4, bioconductor-3 (frozen, STAT=T), nextflow-2, pytorch-4 (known #35).
- almanode1 unreachable ~4 min in run 128 with no reboot or kdump (cause unknown).

## Upstream notes (file only once reproducible)
- Comment on #52: still reproduces 3/3 on merged 2.0-dev `53f0601` (S3 in test-unload-active.sh).
- rmmod hang in kthread_stop / mattx_comm_disconnect (two kdumps, no reproducer yet).
- Ask Matt about home-node-removal semantics; watch whether the blocking-syscalls refactor overlaps #53.
