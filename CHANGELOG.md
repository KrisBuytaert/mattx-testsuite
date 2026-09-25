# Changelog

All notable changes to this test suite are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Known Issues
- **`test-alma`'s Test 2 (network wormhole, `servertestpoll`,
  `brainmatt/mattx#19`) and Test 4 (sustained file I/O across migration,
  `dd_migtest`, `brainmatt/mattx#20`) both fail, reproducibly, on both
  `main` (`2770394`) and `1.9-dev` (`cc5331c`)** — confirmed on multiple
  clean cluster builds across two independent physical hosts, so these
  are real, pre-existing mattx bugs, not host-specific flakiness or
  something introduced by the in-progress DSM work. Test 4 fails
  identically everywhere (process/file stop advancing within 15s of
  migration). Test 2's exact symptom differs slightly by host: on the
  original host the migrated process registers on the target but its
  port is unreachable afterward; on the second host the process doesn't
  register there at all — same test failing, seemingly two different
  severities of the same wormhole break. Everything else in the suite
  passes clean, no oops, on every host and branch tested. Both filed
  upstream; `run-tests.sh`'s failure messages now reference the issue
  numbers directly. Not root-caused — reporting for the maintainer.
- **mattx#16/#17 root-caused and fixed on `1.9-dev`, from a kernel strace
  Matt captured and posted on #16**: `mattx_hooks_exit()` unregistered
  every other kretprobe except `shmat_kprobe` — left registered after
  `rmmod`, it collides with the next `insmod`'s registration attempt for
  the same symbol (`-EINVAL`), which isn't checked, leading to a NULL
  pointer dereference shortly after. Explains the "only the first restart
  after boot crashes" pattern exactly: the leak only happens on the first
  `rmmod`. **Fixed and merged**: `brainmatt/mattx#21`, confirmed by Matt
  on his own end ("service mattx restart has never been more stable"),
  #16 closed. Pulled the merge plus Matt's subsequent DSM work (MESI
  protocol finalized as the default, `dsmstresstest`) into both hosts'
  checkouts — `1.9-dev` is now at `2022351`.
  **This fix only accounts for the `1.9-dev` case, though** — we also
  reproduced the same crash-and-hang symptom on plain `main`, which has
  no `shmat_kprobe` (no DSM code) at all, so it can't be the same root
  cause there. Audited `main`'s own kretprobe/kprobe register/unregister
  symmetry the same way and found none of this bug class present — every
  probe is cleanly unregistered. The `main`-branch hang remains a
  separate, unexplained mystery; we only have the one occurrence, no
  console capture or strace for it. **Tried capturing the guest's serial
  console during a live crash/hang on the original host (3 attempts, up
  to 60s reads, one starting ~6.5 minutes in — well past the kernel's
  hung-task watchdog threshold): zero bytes every time** — not a timing
  miss, genuinely silent throughout, so console capture alone is
  exhausted as a diagnostic path without kdump (not currently configured
  on the guests). See upstream issues #16, #17, and PR #21 for the full
  history.
- **New DSM Test 3 (`scripts/test-dsm.sh`) found a real bug on its first
  run: `shmget()` fails with `EFAULT` ("Bad address") when called through
  the migSHM wormhole as a Surrogate.** The previously-reported "6/6
  passing" DSM suite only ever exercised the `shmdt`/`shmctl` wormhole
  hooks — `dsmtest.c` calls `shmget()`/`shmat()` before Test 2's migration
  point, so those two of the four hooks in `mattx_hooks.c`
  (`shmget`/`shmat`/`shmdt`/`shmctl`) were never actually exercised
  through the wormhole before. Test 3 migrates earlier, before any SHM
  syscall fires, closing that gap — and immediately caught this: the
  worker's very first `shmget()` post-migration fails outright and the
  process hangs there, never reaching its 100-loop run. Reproduced
  cleanly on the second host (see above); Test 1/2 still pass. Filed
  upstream as `brainmatt/mattx#18`.
  **Re-tested against `2022351` (MESI as the new default) under
  `dsm_mode 2` explicitly — still fails, but the failure shape changed**:
  under `dsm_mode 1` the worker got a clean, fast `EFAULT` from `shmget()`
  and exited via its own `perror()` + `exit(1)` (confirmed in
  `dsmtest.c`'s source, which only exits on that path); under `dsm_mode 2`
  the worker produces zero log output at all — not even its pre-migration
  startup line, which should have survived the migration in its stdio
  buffer and only needed a normal `exit()` to flush. Suggests it's now
  hanging somewhere rather than failing fast, though not confirmed
  further. Not root-caused at the source level ourselves.
- **This test host's `libvirtd` doesn't reliably track running VMs**:
  `virsh list`/`net-list` intermittently report nothing while the
  underlying qemu/dnsmasq processes are still alive and healthy. One
  contributing cause found and fixed (see Fixed, below); a second,
  unexplained disappearance was also observed. Host-level libvirt issue,
  not a mattx or test-suite bug — needs root access to debug further.

### Changed
- **Known-issue failures now name their upstream issue directly in the
  `[FAIL]` message** (`run-tests.sh` Test 2 → `brainmatt/mattx#19`, Test 4
  → `brainmatt/mattx#20`; `test-dsm.sh` Test 3's shmget-related failures →
  `brainmatt/mattx#18`), so a run that hits one of these doesn't read as a
  fresh mystery — it's immediately clear which failures are already
  tracked, known-WIP bugs versus something new.
- **`scripts/create-vm.sh` now assigns each VM a static IP via cloud-init
  `network-config` instead of relying on DHCP.** The test harness already
  hardcodes a fixed IP per node everywhere (`node_ip()` in `lib.sh`, the
  MAC reservations in `ensure-libvirt-network.sh`) — DHCP was only ever a
  roundabout way to arrive at an address already known in advance.
  Directly motivated by a second test host where `dnsmasq` on the
  `mattx-test` network silently never answered DHCPDISCOVER requests
  (confirmed via `tcpdump` that the guest's broadcasts reached the bridge;
  `dnsmasq` never even invoked its lease-helper script) — root cause not
  identified, but static IPs sidestep it entirely and remove a moving part
  from provisioning on every host, not just that one.
- **`scripts/create-vm.sh`'s cloud-init now sets a console-only root
  password (`mattx-console`)**, so a VM whose networking never comes up
  can still be diagnosed via `virsh console <vm>` even when SSH is
  completely unreachable. `ssh_pwauth` stays `false`, so this doesn't
  weaken network-facing SSH auth at all — console access only.
- **Split Test 5 (stale cluster link / peer service bounce) out of
  `scripts/run-tests.sh` into its own `scripts/test-stale-link.sh`**
  (`make test-stale-link-alma`/`-deb`/`-ubu`). Test 5's own mechanism is a
  `systemctl restart mattx` on a node — the exact trigger for mattx#16/#17
  (see Known Issues) — so bundling it into the default suite meant that
  upstream kernel bug could take down Tests 1-4's results along with it,
  even though those tests are otherwise unrelated to the stale-link
  scenario. `make test-alma` now covers Tests 1-4 only and finishes
  cleanly on its own. The shared helpers both scripts need
  (`show_location`, `do_migrate`, `check_no_oops`, `process_stat`,
  `is_actually_running`, `repro_setup`) moved into `lib.sh` so they're not
  duplicated between the two.
- **Every report now opens with a version banner**: the exact mattx git
  commit deployed (read from the remote node's own `~/mattx` checkout, not
  just the local source tree, so it reflects what actually got built) and
  each node's running kernel (`uname -r`). Added to `auto_report_wrap()`
  in `lib.sh`, so it applies to every script that uses it (`run-tests.sh`,
  `test-dsm.sh`, `test-stale-link.sh`, `test-mpi.sh`, all `test-eessi-*.sh`)
  with no per-script changes needed. Motivated directly by this session's
  mattx#16/#17 investigation, where "what commit/kernel was this actually
  run on" repeatedly had to be reconstructed after the fact.

### Fixed
- **`scripts/ensure-libvirt-network.sh` retries `virsh net-start` (5
  attempts, 2s apart) before falling back to its destroy+undefine+redefine
  recovery**, instead of recreating the network (and orphaning any
  already-running VM's network attachment) on the very first transient
  failure. See the libvirt flakiness entry above for why this matters.

### Added
- **kdump, on AlmaLinux nodes, verified working end-to-end**:
  `setup-node.sh` now installs `kexec-tools` + `kdump-utils` +
  `makedumpfile` (on RHEL 10, `kexec-tools` alone is only the low-level
  `kexec`/`vmcore-dmesg` binaries — `kdumpctl`/`kdump.service`/
  `/etc/kdump.conf` come from the separate `kdump-utils` package, found
  the hard way after the first attempt installed `kexec-tools` alone and
  `kdumpctl` came back "command not found"), adds `crashkernel=192M`, and
  enables `kdump.service` — piggybacked onto the reboot cycle
  provisioning already does, so it costs nothing extra. Verified for
  real: triggered a live kernel crash (`echo c > /proc/sysrq-trigger`)
  and confirmed a full `vmcore` + auto-extracted `vmcore-dmesg.txt`
  landed in `/var/crash` and was retrievable via the new
  `scripts/fetch-crash-dump.sh <alma|deb|ubu> <1|2|3>` (lists and rsyncs
  `/var/crash` into `test/crash-dumps/<node>-<timestamp>/`, gitignored).
  Real crash/hang diagnosis on our own hosts (not just Matt's) was the
  actual gap all along — repeated live serial console reads during a
  hang came back completely empty (see Known Issues), and it took Matt's
  own kdump-equipped strace to actually root-cause mattx#16/#17 (see
  `brainmatt/mattx#21`); this closes that gap for next time. Debian/Ubuntu
  nodes not covered yet (different tooling, `kdump-tools`, untested).
- **`scripts/report-table.py` (`make report-table`)**: generates a per-run
  summary table (Markdown and HTML) from `test/reports/*.txt` transcripts
  — one row per test run, keyed by kernel version and mattx commit (read
  from each report's new version banner, see above; older reports without
  one show "unknown" rather than being dropped), then date, then a
  compact pass/fail result with the specific failing tests listed. Sorted
  so repeated runs against the same (kernel, commit) sit together.
- **`scripts/test-mpi.sh` (`make test-mpi-alma`/`-deb`/`-ubu`)**: a new,
  dedicated MPI migration test, separate from `test-eessi-osu-shm.sh`.
  Builds and runs upstream's own `bin/mpich/mpitest` debugging pair
  (`mpitest`/`mpitest-client`, MPI_Comm_spawn master+worker) with real
  MPICH (not EESSI's Open MPI -- see note below), migrates the live worker
  mid-count, and requires it to keep advancing at roughly its pre-migration
  rate afterward (not just "moved once"). Per upstream (brainmatt, mattx#15
  comment 2026-09-12), also toggles `echo 'mpi 1' > /proc/mattx/admin` on
  before running and reverts it to `0` in cleanup, since MPI support is off
  by default.
  - Had to switch from EESSI's Open MPI 4.1.5 module to a plain `mpich`/
    `mpich-devel` package install: Open MPI's `MPI_Comm_spawn` hits its own
    `UNPACK-OPAL-VALUE: UNSUPPORTED TYPE 33 FOR KEY` error in this
    environment, reproduced with MattX entirely out of the picture (no
    migration attempted) and independent of `--mca`/`--bind-to` flags tried
    -- an Open MPI/environment issue, not ours to chase, and it matches
    upstream's own `run-mpitest` script targeting MPICH specifically
    (`MPICH_NO_LOCAL` is an MPICH-only knob).
  - MPICH's Hydra launcher also needed `-launcher fork` plus generous
    startup polling (20-30s observed) instead of `mpirun`'s default
    (`--launcher ssh`, even for a same-node spawn): under a detached/no-tty
    SSH launch it would otherwise stall indefinitely at "Spawning
    'mpitest-client'...".

### Known Issues
- **New finding via `test-mpi.sh`: a migrated `MPI_Comm_spawn` worker wakes
  up, runs exactly ONE more loop iteration, then permanently stalls
  (`ps` STAT stays `T`) -- reproduced twice, independently.** Both runs on
  1.9-dev @ `cc5331c` show the same shape: `dmesg` on the receiving node
  logs a fully clean import ("All memory transferred", "Commencing full
  brain transplant", "Successfully injected 30 Fake FDs!", "IT'S ALIVE!
  Waking 3 threads in Gang PID ...") -- no oops, no crash, nothing
  resembling mattx#15's "total silence" -- yet the counter (which should
  advance by 1 every second) only ever advances by exactly one more value
  after migration (6->7 in one run, 3->4 in the other) and then never
  moves again for the rest of a 60s poll window. Unlike the `osu_latency`
  repro, there is no live shared-memory transport in play here at all --
  this is a single MPI_Comm_spawn'd worker with no ongoing MPI traffic
  during its count loop, so the stall looks specific to something about
  resuming an MPI-launched (multi-threaded: "3 threads in Gang") process's
  execution after the "brain transplant", not to shared memory. Not
  root-caused on our end -- reporting for upstream, who's asked for exactly
  this kind of MPI finding to be centralized on mattx#15 as the "MPI master
  bug".

### Fixed
- **`scripts/test-dsm.sh`'s `loop_sequence()` had a stale regex that no
  longer matched `dsmtest`'s log output**, causing both dsmtest cases to
  report a false `FAIL: ... (got 0 entries)` on the 1.9-dev cluster after
  upgrading to commit `cb64731`. Upstream commit `28e11ef` ("make it visible
  that the data in SHM changes") changed `dsmtest.c` to prefix the loop
  number onto the SHM payload itself (`"%d MattX DSM Magic! Loop %d"`
  instead of the old fixed string), so the old
  `Loop \K([0-9]+)(?= - Read from SHM: 'MattX DSM Magic! Loop \1')` pattern
  no longer matched any line. Updated to
  `Loop \K([0-9]+)(?= - Read from SHM: '\1 MattX DSM Magic! Loop \1')`.
  After the fix, `make test-dsm-alma` passes clean: 6/6, including "all 100
  loops continuous and self-consistent across migration" — i.e. **DSM/SysV
  shared-memory migration (mattx#15's underlying scenario) now works
  end-to-end** on 1.9-dev @ `cb64731`, a major change from the total
  receiver-side silence previously reported in mattx#15.

### Known Issues
- **mattx#15's *second* repro (migrating an `osu_latency`/Open MPI rank —
  high-VMA, `MAP_SHARED` shared-memory transport) is NOT fixed, and now
  crashes the *sender* outright.** Only the `dsmtest` (SysV shm) repro from
  that issue was re-verified as fixed (see the "Fixed" entry above) — do not
  read that as mattx#15 being fully resolved. Retested the `osu_latency`
  scenario via `make test-eessi-osu-shm-alma` on the same 1.9-dev @ `cb64731`
  cluster: the instant `migrate <pid> <node2-id>` was issued on almanode1 for
  a live co-located `osu_latency` rank pair, almanode1's own SSH session
  reset (`Connection reset by peer`) and it came back up with `uptime`
  showing a fresh boot. almanode2 was untouched (uptime unaffected) — so this
  time the *source* node crashes during migration extraction, a different
  and arguably worse signature than the original "total silence on the
  receiver" report. No panic backtrace recoverable (same diagnostic gap as
  mattx#16 — no persistent journal, no kdump). Not root-caused further per
  house policy on WIP-branch bugs; reported upstream as a follow-up on
  mattx#15 rather than closing it.
  **2026-09-13 re-confirmation**: re-ran this exact scenario a second time,
  now on `cc5331c` and with `mpi 1` properly enabled beforehand (the first
  repro above had MPI support left off, which upstream later clarified is
  required for MPI tests) — identical crash, same signature, same instant
  timing (SSH resets the moment `migrate` is issued). So this is independent
  of the `mpi` admin toggle, not an artifact of testing with MPI support
  off.
- **mattx#16 (kernel crash/reboot on `systemctl restart mattx` /
  `rmmod mattx`) reproduced again on both almanode1 and almanode2, on the
  latest 1.9-dev commit (`cb64731`)** — hit during the routine
  `make upgrade-alma` restart step (not a special repro attempt). Both nodes
  came back up cleanly on reboot (systemd auto-loads the new module), so it
  cost nothing but a delay, but it means every upgrade/restart cycle on
  1.9-dev still reliably crashes the node. Not yet re-investigated at the
  source level — reporting for the maintainer, not root-causing ourselves.
- **`test-eessi-gromacs-chain.sh` "passes" for the wrong reason — it does
  not actually validate a correct recall, and it silently destroys the real
  computation.** The test was written expecting to prove that the recall
  path resolves the *original* exporting node (`almanode1`) rather than the
  node the job last passed through (`almanode2`). It doesn't test that at
  all, because remote-to-remote forwarding (`almanode2 -> almanode3` while
  the job is already a guest) is not supported by MattX today, and the
  failure mode is silent, not a clean error:
  1. `almanode1`'s `export_registry` entry is written once, at the
     *original* export, and is never updated on a later hop. So after
     `almanode2 -> almanode3`, `almanode1` still believes the job lives on
     `almanode2`.
  2. Forwarding (`mattx_capture_and_send_state()`, `mattx_migr.c`) always
     leaves a frozen local placeholder behind on the sending node — the
     same thing that happens on a normal home-node forward. But when the
     sender is itself a remote guest of a third node, that placeholder
     stays registered as *that* node's Surrogate too, frozen at whatever
     state it was in the instant the second hop began. Forwarding does not
     know or care that the task it's sending is itself already a guest.
  3. `migrate <pid> home`, issued on `almanode1`, sends `RECALL_REQ` to
     `almanode2` (the stale target from step 1) — not `almanode3`, where
     the job actually is.
  4. `almanode2` answers using its frozen placeholder from step 2. This
     "succeeds": `almanode1` gets back a live, running process, and every
     check in this test (is a process present, is it not frozen) passes.
     But the returned state is a stale snapshot from the moment the second
     hop began — none of the computation that ran on `almanode3` for the
     rest of the test is in it.
  5. `almanode3`'s own Surrogate is not just abandoned — it gets
     Assassinated (`mattx_sched.c`'s Funeral Director sees its recorded
     Deputy, the placeholder from step 2, die on `almanode2` when that node
     finishes answering the recall, and kills its own copy in response).
     The real, further-progressed computation is gone, not just orphaned.

  Confirmed live on `almacluster3` by correlating `dmesg -T` timestamps
  across all three nodes for one run: `almanode1` logs
  `[RECALL] Sending RECALL_REQ for PID 95989 to Node 378` (node 378 is
  `almanode2` — should be 379/`almanode3`); `almanode2` logs
  `[EXPORT] Found Surrogate PID 21226. Capturing state...` immediately
  after, using the PID it had frozen since the first forward call and
  never cleared; `almanode3` logs
  `[ASSASSIN] Executing Surrogate PID 14720 (Sending SIGKILL)...` two
  seconds after `almanode2` finishes sending the stale state home. All
  8 assertions in the test still report `[PASS]`, because none of them
  check *which* state came home, only that *some* running process did.

  This is a MattX limitation, not a test bug. It was initially assumed that
  `mattx-admin migrate` (the upstream CLI, `bin/mattx-admin` in the main
  repo) already guards against this, since it refuses a direct
  remote-to-remote hop with "already migrated to node X, please migrate it
  'home' first" — but **that guard has a blind spot and does not actually
  catch this case, confirmed by rerunning the chain with
  `MATTX_TOOL=mattx-admin`**: leg 2 (`almanode2 -> almanode3`) went
  through unchallenged (`NOTICE: PID 22402 is currently running locally,
  migrating it to node 379`), and the same silent stale-state corruption
  followed. The reason: `mattx-admin`'s guard reads `/proc/mattx/remote`,
  which is keyed by `export_registry` (processes *this* node originally
  exported elsewhere) — it has no way to see that a local PID is itself an
  *incoming* guest (`guest_registry`, exposed at `/proc/mattx/guests`) of
  a different node. It only protects against re-forwarding a job whose
  home is the node you're running it from; it does not protect against
  forwarding a Surrogate you're merely hosting. So today, raw
  `/proc/mattx/admin` and `mattx-admin migrate` behave identically for
  this specific case — both let it through, both corrupt state. Fixing
  `mattx-admin` to also check `/proc/mattx/guests` would close this one
  entry point, but the actual bug is in the kernel module (steps 1-3
  above), not the CLI. See "Added" below for `MATTX_TOOL`, which now lets
  every script in this suite exercise both entry points and confirm where
  they agree and where they don't.

- **`test-dsm.sh` (new, SysV shared-memory migration test for
  `bin/dsmtest.c` on 1.9-dev) is expected to fail on the current build.**
  Filed upstream as `brainmatt/mattx#15` and `brainmatt/mattx#16` after
  investigation; being tracked there rather than re-diagnosed here.
  Committed anyway so the repro stays versioned and runnable.

- **`test-eessi-bioconductor.sh`, `test-eessi-nextflow.sh`,
  `test-eessi-openfoam.sh`, `test-eessi-osu-shm.sh`, `test-eessi-pytorch.sh`,
  `test-eessi-quantumespresso.sh`, and `test-eessi-tensorflow.sh` are not
  yet confirmed passing.** As of today, only the basic migration suite
  (`run-tests.sh`) and the GROMACS EESSI suite (`test-eessi-gromacs.sh`,
  including its chain/relay variants) are confirmed working end to end.
  These scripts are committed anyway, each carries a `STATUS:` comment
  near its top saying the same, and a `[FAIL]` from any of them should be
  read as "not yet verified" rather than assumed to be a new regression —
  none has been individually root-caused the way the chain-migration bug
  above has. All seven were already wired into `test-eessi.sh`'s aggregate
  `SUITES` list before being committed here — `test-eessi-osu-shm.sh` has
  since been pulled back out at the maintainer's request (its `STATUS:`
  banner still applies, it's just not part of the aggregate run for now),
  but the other six remain, so a `make test-eessi-<distro>` run's
  aggregate exit code will currently report failure regardless of OSU-SHM.

### Added
- **`scripts/test-eessi-gromacs-relay.sh`** (`make test-eessi-gromacs-relay-alma`,
  `make test-eessi-gromacs-relay-alma-mattx-admin`) — the OTHER way to move
  a job across three nodes: never hop remote-to-remote directly, always
  recall home before migrating anywhere else
  (`node1 -> node2 -> home(node1) -> node3 -> home(node1)`). This is the
  pattern the upstream author says is actually supported, as opposed to the
  direct chain in `test-eessi-gromacs-chain.sh`, which is not. Every
  individual hop here is home<->remote — the same shape
  `test-eessi-gromacs.sh` already validates — so unlike the direct chain,
  this one is expected to actually work. **Confirmed live, in both tool
  modes: it does.** Unlike the chain test, this one doesn't just check "is
  a process running" — it also compares cumulative CPU time
  (`ps -o cputimes`) on the *same* PID at two points that both resurrect
  the original home-node task_struct (right after the node2 recall, and
  right after the node3 recall), which is exactly the signal that would
  catch a stale-state resurrection like the one in the chain test. Live
  numbers from one run: 62s → 109s (mattx-admin) and 62s → 107s (raw) —
  genuine forward progress in both cases, not a rewind.
- **`MATTX_TOOL` env var** (`raw` (default) or `mattx-admin`), read by a new
  `mattx_migrate()`/`mattx_tool_label()` pair in `lib.sh` and now used by
  every `do_migrate()` in this suite (`run-tests.sh` and every
  `test-eessi-*.sh` script, including the chain test). `raw` keeps this
  suite's original behavior (`echo migrate <pid> <target> | sudo tee
  /proc/mattx/admin`); `mattx-admin` instead shells out to the upstream
  `mattx-admin migrate <pid> <target>` CLI already deployed to every test
  node. Run any suite with `MATTX_TOOL=mattx-admin make test-eessi-...` (or
  `make test-eessi-gromacs-chain-alma-mattx-admin` for the chain test
  specifically) to compare the two entry points against the same
  underlying kernel operation — see "Known Issues" above for a case where
  they turned out to agree in a way nobody wanted.
- **3-node GROMACS chain migration test** (`scripts/test-eessi-gromacs-chain.sh`,
  `make almacluster3`, `make test-eessi-gromacs-chain-alma`) — exercises
  `node1 -> node2 -> node3 -> node1`, the one thing a 2-node cluster
  structurally can't test: whether the recall path resolves the *true*
  origin node rather than just the node the job last passed through.
  `almanode3` is fully isolated from the normal 2-node workflow (separate
  stamps/targets throughout `create-vm.sh`, `deploy-mattx.sh`,
  `ensure-mattx-running.sh`, `setup-eessi.sh`, `setup-node.sh`,
  `start-mattx.sh`, `lib.sh`, and the `Makefile`) — the ordinary 2-node
  AlmaLinux workflow never provisions or touches it.
- **GROMACS `expel` return-leg test** (Test 5 in `test-eessi-gromacs.sh`) —
  per upstream maintainer guidance in
  [brainmatt/mattx#8](https://github.com/brainmatt/mattx/issues/8#issuecomment-5458346309),
  covers the `expel <local-surrogate-pid>` return-migration entry point
  (issued on the node hosting the surrogate) independently of the existing
  `migrate <pid> home` recall test (issued on the home node) — both call
  the same underlying return-capture code, but from different admin
  commands and different nodes.
- `lib.sh`: `dmesg_cursor()` / `no_new_oops()` helpers, shared across every
  EESSI test script.

### Changed
- `test-eessi.sh` rewritten to invoke every `test-eessi-*.sh` workload suite
  and aggregate their real exit codes, not just count `[FAIL]` lines — a
  suite that crashes before printing one no longer makes the aggregate
  report "0 failed".
- Kernel-oops checks across all EESSI scripts now scope to what's new in
  `dmesg` since the test started (via `dmesg_cursor`/`no_new_oops`),
  instead of scanning the whole ring buffer — a stale oops from an earlier
  run no longer causes every later run to report a false failure.
- README: documented the chain migration target, the previously
  undocumented Test 4 (`dd_migtest` sustained file I/O), the new `expel`
  test, and refreshed the ESPResSo "known gap" note to describe the actual
  current limitation (`epoll`/`eventfd` doesn't survive migration) instead
  of a stale packaging issue that no longer applies.
- `make all`'s help text trimmed down to the workload suites that are
  actually working (GROMACS, ESPResSo, the chain test). QuantumESPRESSO,
  OpenFOAM, PyTorch, TensorFlow, Bioconductor, and Nextflow scripts are
  still being worked on and deliberately not staged yet, so their targets
  stay directly runnable but aren't advertised as ready.

### Fixed
- `test-eessi.sh`: a `while read <<< "$SUITES"` here-string loop was
  vulnerable to a classic bash pitfall — any `ssh` call inside the loop
  body (which every suite makes many of) silently drains the loop's
  remaining unread lines from stdin, so every suite after the first one
  that made an SSH call simply never ran. Fixed by reading the suite list
  into an array first.
- `run-tests.sh`: Test 1/2/3 now validate that the discovered worker PID is
  actually numeric before migrating it, instead of possibly migrating an
  empty PID or (Test 3 specifically) aborting the whole script via an
  unguarded `pgrep` under `set -e`. Also added a distro-validation default
  branch so an unrecognized distro argument fails with a clear usage
  message instead of proceeding with unset node variables.
- A self-kill bug introduced while fixing cleanup traps to use `pkill -9`
  (needed because plain `SIGTERM` doesn't affect MattX-frozen `STAT=T`
  processes — they're stopped and won't act on it until resumed): the
  usual bracket self-protection trick (`pkill -f '[x]pattern'`) only
  guards a pattern's own invocation text, not a *different* part of the
  same combined `ssh` command string. If a later argument on that same
  command line (e.g. a file path like `dd_migtest.dat`) contains the raw
  pattern unescaped, `pkill -9` matches its own parent shell's full
  cmdline and kills it mid-script, before the rest of the command ever
  runs. Fixed by splitting the two affected commands (`run-tests.sh`'s
  `dd_migtest` cleanup, `test-eessi-gromacs.sh`) into separate `ssh`
  calls — confirmed no other script has the same combination.
- **`do_migrate()`'s log output was actively misleading for the "recall
  home" case**, across every script that has one (`run-tests.sh` and all 9
  EESSI workload scripts): it printed `from: <home_node> ... to: <home_node>`
  for a migration that was actually returning the job from wherever it
  currently lived (e.g. `almanode2`) back to the home node — because the
  admin command genuinely has to be issued *on* the home node (that's a
  real MattX requirement, not a display choice), and the helper reused
  that same node for the "from" label too. Fixed by adding an optional
  6th `actual_from` parameter that carries the *real* current location for
  display, while the admin command still runs on the home node as
  required; also now prints the literal `migrate <pid> <target>` command
  being sent, not just a paraphrase of it.
- **`show_threads()`'s `ps` format used `comm` instead of `cmd`**
  (`test-eessi-gromacs.sh`, `test-eessi-tensorflow.sh`,
  `test-eessi-espresso.sh`, `test-eessi-pytorch.sh`) — see the "`ps`
  column gotcha" note in the README. Every one of these thread-level
  snapshots was silently reporting "no threads matching" regardless of
  whether the process was actually there, for as long as this code has
  existed.
- **`run-tests.sh` Test 2's wormhole reachability check raced the
  migration it was checking** — it waited for the process to *appear* on
  the destination node, then checked TCP reachability immediately, but a
  socket-holding process needs several extra syscall-replay round trips
  (`bind`/`listen`/etc.) through the wormhole *after* it's already visible
  in `ps`. Fixed by polling the reachability check (up to 20s) instead of
  testing it once.

### Removed
- `scripts/run-tests-ng.sh` — confirmed unreferenced by any Makefile
  target or other script; a divergent, unmaintained alternative to
  `run-tests.sh` that had drifted out of sync (no report wrapping,
  excluded Ubuntu, migrated the server process directly rather than the
  worker).
