# Changelog

All notable changes to this test suite are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Known Issues
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
