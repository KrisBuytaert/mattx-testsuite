# CI: how the MattX regression runs work and how to trigger them

Reference for the Forgejo CI that runs this test suite against the mattx
upstream branches, publishes the results, and how to start, watch and debug a
run by hand.

## 1. The moving parts

| Piece | Where | Role |
|---|---|---|
| Harness (this repo) | GitHub `KrisBuytaert/mattx-testsuite`, mirrored to Forgejo `vox/mattx-testsuite` | Makefile, `scripts/`, workflows in `.forgejo/workflows/` |
| mattx under test | GitHub `brainmatt/mattx`, mirrored to Forgejo `vox/mattx` | tracked branches: `1.9-dev`, `main` |
| Forgejo | `https://forgejo.lab.kribu.be` (loopback `http://127.0.0.1:3020` on fedora-lab) | schedules workflow runs |
| Runner `fedora-lab-mattx` | fedora-lab, systemd unit `forgejo-runner-mattx`, user `forgejo-runner-mattx` (groups: `libvirt`) | executes jobs **directly on the host** (label `mattx-host`, no containers) |
| Podman runner `fedora-lab` | systemd unit `forgejo-runner`, label `docker` | other repos' container jobs; not used here |
| Test cluster | libvirt VMs `almanode1..3` on `qemu:///system`, network `mattx-test` | what the suites run against |
| Archive | Forgejo `vox/mattx-testsuite-reports` (private) | raw, unscrubbed reports |
| Public page | GitHub Pages, `KrisBuytaert/mattx-test-reports`, served at `https://krisbuytaert.be/mattx-test-reports/` | scrubbed reports + summary table |

Runner, label and Puppet profiles are managed in `/home/src/puppetry`
(`profile_forgejo::runner_host`, ADR-0021). Repos are managed in
`/home/src/tofu-forgejo` (`repos.auto.tfvars`).

## 2. What a run does

Workflow `mattx-ci` (`.forgejo/workflows/mattx-ci.yml`), three jobs in order:

1. **functional**: sync the harness into the persistent directory, fetch mattx at
   the requested branch/commit, `make upgrade-alma3` (build + deploy to the
   nodes), then `make -k test-alma test-dsm-alma test-stale-link-alma
   test-dsm-mesi3-alma test-unload-alma test-admin-input-alma`, fetch kdump crash dumps, **publish** the reports.
2. **gate**: decides whether the long suites run (`reason` output). `ok` only if
   `functional` succeeded, **every fast suite passed** (no `failed` count above 0, no
   missing Results line, read from this run's reports) **and** neither the mattx branch tip nor testsuite
   master has moved since the run started. Otherwise `moved`,
   `tests-failed`, `functional-failed` or `disabled` (`run_eessi=false`). A pinned `mattx_sha`
   ignores mattx moving.
3. **eessi**: runs only when the gate says `ok`. First clones/updates the **upstream**
   `github.com/EESSI/eessi-demo` into `~forgejo-runner-mattx/eessi-demo-src` and links it
   as `$H/eessi-demo` (locally `eessi-demo` is a gitignored symlink to a personal fork,
   which CI cannot see). `make -k test-eessi-alma` (the
   long EESSI application suites: gromacs, pytorch, mpi, ...), crash dumps,
   publish again.
4. **record**: always runs last. Writes the tested pair
   (`<mattx sha> <testsuite sha>`) to `~forgejo-runner-mattx/last-tested.<branch>`
   so the poller does not retrigger a run that broke early, and the same pair to
   `last-eessi.<branch>` unless the gate said `moved`.

No avalanche: a busy branch gets the fast suites per push and no long run. When a
pair is tested but its long suites are still owed (`last-eessi` differs) and the
tip has been unchanged for `QUIET_HOURS` (default 6), the poller dispatches it
again and, being quiet, the gate lets the long suites through.

Test steps use `continue-on-error`, so **a failing test does not turn the run
red**; the results are in the published reports. Only infrastructure steps
(sync, build/deploy) fail the job. There is no known-failures gate yet.

Only one run uses the cluster at a time: the workflow has
`concurrency: group: mattx-cluster` (no cancel), so a second dispatch waits in
status `waiting` until the first finishes.

### Persistent state (not in the job workspace)

Everything stateful lives in `/var/lib/forgejo-runner-mattx/` (mode 0700, owned
by the runner user):

| Path | What |
|---|---|
| `harness/` | the harness code (rsynced from the checkout each run) |
| `harness/.stamp/` | which VMs/network/EESSI already exist. A missing stamp makes `make` try to (re)create the VMs. Seeded for `network alma-vms alma-vms3 alma-eessi alma-eessi3` |
| `harness/keys/mattx_test(.pub)` | ssh key for the VMs |
| `harness/reports/` | full report history, the page table is built from it |
| `harness/crash-dumps/` | fetched kdump vmcores |
| `pages_deploy` | write-only deploy key for the GitHub Pages repo |
| `mattx-src/` | clone of brainmatt/mattx used as `MATTX_SRC` |
| `last-tested.<branch>` | poller state, one file per tracked branch |
| `last-eessi.<branch>` | pair whose long suites are done (or deliberately not owed) |
| `seen.<branch>` | `<mattx sha> <testsuite sha> <epoch first seen>`, for the quiet period |

## 3. Triggering a run

All triggers end up as a `workflow_dispatch` of `mattx-ci.yml` on `master`.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `mattx_ref` | `1.9-dev` | mattx branch to test (`1.9-dev` or `main`) |
| `mattx_sha` | empty | exact mattx commit; overrides `mattx_ref` |
| `mattx_repo` | `brainmatt/mattx` | GitHub `owner/repo` to test; a fork such as `KrisBuytaert/mattx` to test a fix branch before it is merged |
| `run_eessi` | `true` | `false` = functional suites only |
| `force_eessi` | `false` | `true` = run the long suites even if fast suites failed or a newer commit exists (still needs the functional job to succeed) |

### A. Web UI

`https://forgejo.lab.kribu.be/vox/mattx-testsuite/actions` -> workflow `mattx-ci`
-> **Run workflow**, pick the branch `master`, fill the inputs.

### B. API (works from fedora-lab, scriptable)

Needs an API token with Actions read/write on `vox/mattx-testsuite` (the same
token `tofu-forgejo` uses is in `/home/src/tofu-forgejo/.env` as
`TF_VAR_forgejo_api_token`; never print it or put it in a command that gets
logged).

```bash
set -a; source /home/src/tofu-forgejo/.env; set +a
T="Authorization: token $TF_VAR_forgejo_api_token"
B=http://127.0.0.1:3020/api/v1/repos/vox/mattx-testsuite

# functional suites only, 1.9-dev
curl -s -w '%{http_code}\n' -X POST -H "$T" -H 'Content-Type: application/json' \
  -d '{"ref":"master","inputs":{"mattx_ref":"1.9-dev","run_eessi":"false"}}' \
  $B/actions/workflows/mattx-ci.yml/dispatches          # 204 = accepted

# everything, branch main
curl ... -d '{"ref":"master","inputs":{"mattx_ref":"main"}}' ...

# an exact commit
curl ... -d '{"ref":"master","inputs":{"mattx_sha":"b401a0e"}}' ...
```

HTTP `204` means the dispatch was accepted. `500` with a `yaml:` message means
the workflow file on the Forgejo mirror is not valid YAML.

### Following fork branches until they are merged

`ci/tracked.conf` lists what the poller follows, one `<owner/repo> <branch>` per line
(upstream `1.9-dev` and `main`, plus the fix branches on `KrisBuytaert/mattx`). The poller
reads it from GitHub `master` on every tick, so adding a branch is a commit to that file.
A branch outside `brainmatt/mattx` is followed until its PR into `brainmatt/mattx` is merged
or the branch is deleted; after that the poller skips it and logs that it can be removed.
Poller state files use `ci/branch-key.sh` (`1.9-dev`, or `KrisBuytaert_fix_foo` for forks).
The run is shown in the Telegram message and in the report banner / results table as
`owner/repo@branch` (the **Branch** column, searchable).

### C. The poller (automatic, per commit)

`ci/poll-and-dispatch.sh`, meant to run from a systemd timer **as
`forgejo-runner-mattx`** every 15-30 minutes. For each branch in `BRANCHES`
(default `1.9-dev main`) it compares `(branch tip, testsuite master tip)` with
`last-tested.<branch>`; if different it dispatches `mattx-ci` with that
`mattx_ref`. At most one dispatch per tick, and **none while any run is
`running`/`waiting`**, so state recorded at the end of a run is never raced.
Env: `FORGEJO_URL`, `FORGEJO_TOKEN` (and optionally `FORGEJO_CA`, `BRANCHES`,
`STATE_DIR`, `QUIET_HOURS`). Dry run: `DRY_RUN=1 ci/poll-and-dispatch.sh` prints
`would dispatch <branch> ...` or `run active, skipping` and sends nothing.

**Status:** the script is tested with `DRY_RUN`; the **systemd timer, env file and
token are not deployed yet** (to be added to the runner Puppet class). Until then
use A or B.

To force a retest of a branch the poller thinks is done, delete
`~forgejo-runner-mattx/last-tested.<branch>` (as root) or just dispatch by hand.

### D. Without CI (by hand on the host)

From a checkout of this repo, as a user in the `libvirt` group:
`make test-alma`, `make test-dsm-alma`, `make test-stale-link-alma`,
`make test-dsm-mesi3-alma`, `make test-eessi-alma`, `MATTX_SRC=/path/to/mattx/
make upgrade-alma3`. `make report-table` builds `reports/run-summary.{md,html}`;
`scripts/publish-pages.sh [--dry-run]` publishes (needs `keys/pages_deploy`).

## 4. Important: workflow changes reach Forgejo via the mirror

Forgejo runs the workflow file **from its mirror** `vox/mattx-testsuite`, which
only pulls from GitHub every 8 hours. After pushing a workflow or script change to
GitHub, sync immediately:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "$T" \
  http://127.0.0.1:3020/api/v1/repos/vox/mattx-testsuite/mirror-sync   # 200
```

A run already started keeps the workflow definition it started with.

## 5. Watching a run and reading results

Forgejo shows two numbers: the **run number** in the UI (`#5`) and an
instance-wide **task id** in the tasks API (`57`). They are the same run.

```bash
# runs, newest first (index_in_repo = the number in the UI)
curl -s -H "$T" "$B/actions/runs?limit=5" | python3 -m json.tool | less
# tasks (only jobs that have started; a run blocked by concurrency has none yet)
curl -s -H "$T" "$B/actions/tasks?limit=5"
```

* Web UI: `https://forgejo.lab.kribu.be/vox/mattx-testsuite/actions/runs/<n>`
  (full step logs).
* Job logs via the API: list the jobs of a run, then fetch one job's log as text.
  Note these use the **run id** (`id` in `/actions/runs`), not the UI number:
  `GET $B/actions/runs/<run id>/jobs` then `GET $B/actions/jobs/<job id>/logs`
  (`GET $B/actions/runs/<run id>/logs` returns all jobs as a zip).
* Runner log: `journalctl -u forgejo-runner-mattx -f`.
* Results: the published page, and the raw files in
  `/var/lib/forgejo-runner-mattx/harness/reports/` (root only). The page table
  is keyed by kernel version and mattx commit.
* Status values: `waiting` (queued or blocked by `mattx-cluster`), `running`,
  `success`, `failure`, `cancelled`, `skipped`. `success` only means the
  infrastructure steps worked; read the reports for test results.

### Notifications (Telegram)

Forgejo itself sends a Telegram message when a run fails and when it recovers: a
`telegram` webhook on `vox/mattx-testsuite` (events `action_run_failure`,
`action_run_recover`), managed in `/home/src/tofu-forgejo/webhooks.tf`; the bot
token comes from that repo's `.env` (`TF_VAR_telegram_bot_token`). Because
Forgejo fires it, it still reports when the runner is down or a run is
cancelled. Reminder: "failure" means an infrastructure step failed (sync,
build/deploy, hung node); failing *tests* do not fail a run. To test the
webhook, dispatch `notify-test.yml` with `outcome` `fail` or `pass`.

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Run stays `waiting` | another run holds `mattx-cluster` (normal), or the runner is down: `systemctl status forgejo-runner-mattx`; runner shows `labels: [mattx-host]` in its journal |
| Dispatch returns 500 `yaml:` | invalid workflow YAML on the mirror; fix, push, `mirror-sync` |
| Dispatch returns 404 | workflow not on the mirror yet: `mirror-sync` |
| `harness not provisioned: ... missing` | the persistent dir lost `keys/mattx_test` or `.stamp/`; recreate as root (see section 2 table), do not let `make` regenerate keys |
| `make` starts creating VMs | `.stamp/` entries missing; the VMs exist, so seed the stamps instead |
| Poller says `run active` forever | a run is stuck `running`/`waiting`; cancel it in the UI |
| Poller redispatches the same commit | the `record` job did not write `last-tested.<branch>` (check the run), or the testsuite master moved |
| Runner `permission denied ... /run/podman/podman.sock` | that is the *Podman* runner (`forgejo-runner`), not this one; `/run/podman` needs mode 0755 (drop-in `DirectoryMode`) |
| Page did not update | `publish-pages.sh` failed in the last step of a job; check `$HOME/pages_deploy` exists (0600) and the Pages repo deploy key is still enabled |
| Node rebooted mid-run | a kernel crash; vmcore is fetched into `harness/crash-dumps/`, headline in `vmcore-dmesg.txt` |

## 7. Provisioning the runner host (one time)

Normally Puppet (`profile_forgejo::runner_host`) creates the user, config and
unit. The data it does not create, as root:

```bash
S=/path/to/test; R=/var/lib/forgejo-runner-mattx
U='-o forgejo-runner-mattx -g forgejo-runner-mattx'
install -d $U -m 0700 $R/harness $R/harness/{keys,.stamp,reports,crash-dumps}
install $U -m 0600 $S/keys/mattx_test     $R/harness/keys/mattx_test
install $U -m 0644 $S/keys/mattx_test.pub $R/harness/keys/mattx_test.pub
install $U -m 0600 $S/keys/pages_deploy   $R/pages_deploy
for f in network alma-vms alma-vms3 alma-eessi alma-eessi3; do
  install $U -m 0644 /dev/null $R/harness/.stamp/$f; done
install $U -m 0644 $S/reports/*.txt $R/harness/reports/
```

Check the setup without running the suites: dispatch `runner-smoke.yml`
(read-only). It writes its findings to `/tmp/mattx-runner-smoke.log`
(identity, libvirt domains/networks, tool presence, harness paths, ssh to the
three nodes with the harness key, GitHub access with the Pages key).

## 8. Known limits (as of this writing)

* No known-failures gate: runs are green even when targets fail.
* The poller timer/env/token are not deployed.
* Deploys crash a node: `start-mattx.sh` does `rmmod mattx` first, which oopses
  (upstream issue #36); the node reboots and the run may wedge or fail.
* The report banner does not record the mattx **branch**, only the commit.
* New reports are published to Pages but not yet pushed to
  `vox/mattx-testsuite-reports`.
* The EESSI suites can run for hours; check the runner's job timeout before
  relying on a full run (`runner.timeout` in `/etc/forgejo-runner-mattx/config.yml`).
