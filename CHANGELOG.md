# Changelog

All notable changes to this test suite are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
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
