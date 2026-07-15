# EESSI / GROMACS round-trip migration — reproduction & validation guide

**Bead:** `mt-985.3` — Bring up EESSI (CVMFS) on the cluster and get GROMACS working
**Cluster:** Debian 13 (trixie), 2-node MattX cluster (`debnode1` 192.168.100.21, `debnode2` 192.168.100.22)
**Result:** ✅ GROMACS migrated `debnode1 → debnode2 → debnode1` successfully — 8/8 checks passed, no kernel oops.

Raw terminal output from the run this documents is in
[`reports/eessi-gromacs-2026-07-14.txt`](./eessi-gromacs-2026-07-14.txt). This
file explains what that run proved and exactly how to redo it by hand.

## What was validated

1. EESSI 2025.06's GROMACS module (`GROMACS/2025.2-foss-2025a`) loads cleanly on a MattX cluster node.
2. GROMACS actually runs real work via EESSI (`ion_channel` PRACE benchmark, 1000 steps) — 2.203 ns/day on `debnode1`.
3. A **live** `gmx mdrun` process can be migrated by MattX from `debnode1` to `debnode2` while running, verified via `ps` on the target node.
4. It keeps running on `debnode2` (checked again 15s later — not just present immediately after migration).
5. It can be migrated **back** from `debnode2` to `debnode1` — the actual round trip, not just a one-way hop.
6. It keeps running (or completes cleanly) back on `debnode1`.
7. No kernel oops/BUG on either node at any point in the sequence.

## Prerequisites

- Host with libvirt/KVM available, `sdog` (or whoever runs this) in the `libvirt` group.
- Run `make check` from the repo root first — verifies `virsh`, `virt-install`, `qemu-img`, `rsync`, `curl`, and an ISO tool are present, and that you can write to `/var/lib/libvirt/images/`. Run `make setup` once if it complains.
- Outbound internet access on the VMs — EESSI's CVMFS layer and the GROMACS PRACE benchmark input both fetch over the network the first time.

## Manual reproduction, step by step

```sh
# 1. Provision a clean 2-node Debian cluster (skip if one is already up and validated by mt-985.2)
make clean-deb        # only if a stale cluster exists — destroys VMs + disks
make debcluster        # provisions debnode1/debnode2, builds + deploys MattX, starts it

# 2. Install CVMFS + configure EESSI on both nodes (idempotent, stamp-guarded)
make setup-eessi-deb

# 3. Optional: quick sanity check that EESSI itself is reachable before running GROMACS
make test-eessi-deb

# 4. The actual deliverable: GROMACS round-trip migration test
make test-eessi-gromacs-deb
```

`test-eessi-gromacs-deb` runs `scripts/test-eessi-gromacs.sh deb`, which does the following against `debnode1`/`debnode2`:

| Step | What it does | What "pass" looks like |
|---|---|---|
| Test 1 | Loads the EESSI GROMACS module on `debnode1` | `gmx --version` succeeds |
| Test 2 | Runs the `ion_channel` PRACE benchmark (1000 steps) | `logfile.log` written, no timeout (600s cap) |
| Test 3 | Starts a 20000-step `gmx mdrun` in the background on `debnode1`, migrates it to `debnode2` via `echo 'migrate <pid> <node_id>' > /proc/mattx/admin`, confirms it's alive there via `ps`, waits 15s and checks again | Process visible on `debnode2`, still running after 15s |
| Test 4 | Migrates the same process back `debnode2 → debnode1`, confirms it's alive there, waits 15s, checks `dmesg` on both nodes for oops | Process visible on `debnode1` (running or completed cleanly), zero oops on either node |

Expect this to take on the order of 10-15 minutes end to end (VM provisioning
and CVMFS's first cache-warming fetch are the slow parts; the migration steps
themselves are seconds).

## Interpreting the output

- `[PASS] gromacs-N: ...` / `[FAIL] gromacs-N: ...` lines are the individual checks; the script exits non-zero if any failed.
- The final line `GROMACS Results: N passed, M failed` is the one-line summary — `8 passed, 0 failed` is the clean run this report documents.
- If Test 3/4 fails with "gmx mdrun not found" after a migration, the script automatically dumps the last 20 lines of `dmesg` on the relevant node — check that output first, it usually points straight at the cause.
- If the benchmark step (Test 2) fails to download `GROMACS_TestCaseA.tar.gz`, that's a network-access problem on the VM, not a MattX/EESSI problem.

## Cleanup

```sh
make clean-deb   # destroys debnode1/debnode2 and their disks — only do this once you're done
```

The run this report documents did exactly this afterward — no VMs were left running.

## Known intermittent issue (not blocking, but can recur)

A separate run of this same test occasionally hit a different failure: the
migrated `gmx` process crashes with `trap invalid opcode` immediately after
being resumed on the target node. This looks like an upstream MattX
kernel-module bug in FPU/AVX register-state restoration during migration (the
EESSI GROMACS build is AVX2-optimized, "haswell") — **distinct** from the
already-known Guest Watcher race (`mt-8i8`). It did not reproduce on the run
documented here, but if `test-eessi-gromacs-deb` fails with a `gmx` crash
immediately after a migration step rather than a normal test failure, this is
almost certainly it. Tracked as `mt-od4` (open, not yet reported upstream).

## Infra fixes that were needed to get this test running at all

These were pre-existing bugs in the testsuite itself, unrelated to MattX,
fixed as part of this bead (see git log, commit "fix: unblock Debian cluster
provisioning (mt-985.3)"):

- `scripts/setup-node.sh` — the apt dpkg-lock wait loop was checking the wrong lock.
- `scripts/sources.conf` — `MATTX_SRC` pointed at a nonexistent path.
- `scripts/start-mattx.sh` — referenced a nonexistent `mattx-discd.service` unit (the installed unit is named `mattx.service`).
- `scripts/test-eessi-gromacs.sh` — the `GMX_PID` capture was picking up EESSI/Lmod's init banner text from stdout instead of isolating the trailing `echo $!`, corrupting every later `kill`/`ps` use of the PID.

If you're reproducing this on a fresh checkout and hit any of these same
symptoms, check you're on a commit at or after that fix first.
