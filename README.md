# MattX Automated Test Suite


Put this repository as a submodule in your MattX  test/ project.

This is meant to easily spin up a test environment that allows you to test MattX



Fully automated 2-node cluster provisioning and migration smoke tests for
[MattX](https://github.com/brainmatt/mattx), targeting Debian 13 (trixie), Ubuntu 26.04 and AlmaLinux 10.

VMs are created from official qcow2 cloud images using libvirt directly —
no Vagrant, no OS installer. SSH keys and hostname configuration are injected
at first boot via a cloud-init NoCloud seed ISO.

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `libvirt` + `qemu-kvm` | VM hypervisor |
| `virt-install` | VM definition |
| `qemu-img` | Thin-clone VM disks |
| `virsh` | Network + VM management |
| `genisoimage` or `cloud-localds` | Build cloud-init seed ISOs |
| `rsync`, `curl`, `ssh` | Source sync and image download |

On Fedora/RHEL:
```bash
sudo dnf install libvirt virt-install qemu-img genisoimage rsync curl
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $(whoami)   # re-login after this
```

On Debian/Ubuntu:
```bash
sudo apt-get install libvirt-daemon-system virtinst qemu-utils genisoimage rsync curl
sudo usermod -aG libvirt $(whoami)
```

---

## Fixed IP Addresses

| VM | Hostname | IP |
|----|----------|----|
| AlmaLinux node 1 | `almanode1` | 192.168.100.11 |
| AlmaLinux node 2 | `almanode2` | 192.168.100.12 |
| AlmaLinux node 3 *(chain-migration tests only)* | `almanode3` | 192.168.100.13 |
| Debian node 1 | `debnode1` | 192.168.100.21 |
| Debian node 2 | `debnode2` | 192.168.100.22 |
| Ubuntu node 1 | `ubunode1` | 192.168.100.31 |
| Ubuntu node 2 | `ubunode2` | 192.168.100.32 |

All VMs share the `mattx-test` libvirt NAT network (192.168.100.0/24).
IPs are fixed via MAC→IP DHCP reservations. Nodes can reach each other
and have internet access via NAT through the host.

`almanode3` is provisioned separately from the normal 2-node AlmaLinux
cluster (see `make almacluster3` below) — it exists purely to test a
migration chain across more than two nodes, and the ordinary 2-node
workflow never touches it.

---

## Make Targets

```
make alma          Provision single AlmaLinux 10 node (almanode1)
make debian        Provision single Debian 13 node   (debnode1)
make ubuntu        Provision single Ubuntu 26.04 node   (ubunode1)
make almacluster   2-node AlmaLinux cluster: provision + build + deploy MattX
make almacluster3  3-node AlmaLinux cluster: adds almanode3 for chain-migration tests
make debcluster    2-node Debian cluster:    provision + build + deploy MattX
make ubucluster    2-node Ubuntu cluster:    provision + build + deploy MattX
make allclusters   All clusters (use -j3 to run in parallel)
make test-alma     Run migration smoke tests on AlmaLinux cluster
make test-deb      Run migration smoke tests on Debian cluster
make test-ubu      Run migration smoke tests on Ubuntu cluster
make test-stale-link-alma  Run the stale cluster-link regression test (isolated from
                            test-alma since its own trigger — restarting a node's
                            mattx service — can itself crash/hang the node; see the
                            Test 5 section below)
make test-dsm-alma          Run the SysV shared-memory migration (DSM) test suite
make test-dsm-mesi3-alma    Run the 3-node MESI coherency regression test (needs
                             almacluster3 — see "3-Node Chain Migration" below)
make report-table  Regenerate reports/run-summary.md and .html from every report
                   under reports/ (also happens automatically at the end of every
                   test run — see "Test Reports" below)
make setup-eessi-alma          Install CVMFS + EESSI on AlmaLinux cluster
make setup-eessi-deb           Install CVMFS + EESSI on Debian cluster
make test-eessi-alma           Run full EESSI test suite on AlmaLinux
make test-eessi-deb            Run full EESSI test suite on Debian
make test-eessi-gromacs-alma   Run only the GROMACS EESSI tests on AlmaLinux
make test-eessi-gromacs-deb    Run only the GROMACS EESSI tests on Debian
make test-eessi-gromacs-chain-alma  Run the 3-node GROMACS chain migration test (needs almacluster3)
make test-eessi-espresso-alma  Run only the ESPResSo EESSI tests on AlmaLinux
make test-eessi-espresso-deb   Run only the ESPResSo EESSI tests on Debian
make clean-alma    Destroy AlmaLinux VMs
make clean-deb     Destroy Debian VMs
make clean-ubu     Destroy Ubuntu VMs
make clean         Destroy all VMs and stamps
```

All cluster targets are **idempotent**: stamp files under `.stamp/` track
completed steps, so re-running picks up where it left off.

---

## Quick Start

```bash
# Single Debian node (smoke-test the provisioning)
make debian

# Full Debian cluster with MattX installed and running
make debcluster

# SSH into a node
ssh mattx@192.168.100.21 -i keys/mattx_test

# Run migration tests
make test-deb

# Tear it down
make clean-deb
```

---

## How It Works

### 1. SSH Keypair (`make keys`)

An Ed25519 keypair is generated once at `test/keys/mattx_test` (gitignored).
The public key is injected into every VM at cloud-init time.

### 2. libvirt Network (`scripts/ensure-libvirt-network.sh`)

Creates the `mattx-test` NAT network with DHCP reservations mapping each
VM's MAC address to its fixed IP. Called automatically before any VM is
created; idempotent if the network is already active.

### 3. VM Creation (`scripts/create-vm.sh <alma|deb|ubu> <1|2>`)

1. Downloads the official cloud image to `/var/lib/libvirt/images/mattx-test/`
   (once; subsequent runs reuse it):
   - AlmaLinux 10: `AlmaLinux-10-GenericCloud-latest.x86_64.qcow2`
   - Debian 13: `debian-13-genericcloud-amd64.qcow2`
   - Ubuntu 26.04: `resolute-server-cloudimg-amd64.img`
2. Creates a **thin qcow2 clone** (10 GB sparse, backed by the base image).
3. Writes a **cloud-init seed ISO** (NoCloud datasource) containing:
   - `user-data`: creates the `mattx` user with passwordless sudo and the
     generated SSH public key
   - `meta-data`: sets the hostname
4. Calls `virt-install --import` to define and start the VM.

### 4. Node Setup (`scripts/setup-node.sh <alma|deb|ubu> <1|2>`)

Polls until SSH is available, then:
- Installs build dependencies (`gcc`, `make`, `git`, kernel headers, `libnl`, etc.)
- Adds the peer node to `/etc/hosts`

### 5. Build & Deploy

- `scripts/build-mattx.sh` — rsyncs the MattX source tree from the host to
  `node1`, runs `make` + `sudo make install`, and updates `/etc/mattx.conf`
  with the correct cluster interface.
- `scripts/deploy-mattx.sh` — relays the built tree from `node1` to `node2`
  via the host (rsync down, rsync up), then runs `sudo make install` on `node2`.

### 6. Start MattX (`scripts/start-mattx.sh <alma|deb|ubu> <1|2>`)

On each node: `rmmod`/`insmod` both modules, `systemctl restart mattx-discd`,
disables the load balancer, and mounts MattXFS at `/mattxfs`.

---

## Test Scenarios (`scripts/run-tests.sh`)

All tests run from the host over SSH. Each checks for kernel oops in `dmesg`
after completion.

```
make test-deb    # or make test-alma or make test-ubu
```

### Test 1 — Basic migration (migtest)
Starts `migtest` (CPU-bound loop) on node1, migrates it to node2, verifies
the Deputy is present on node1 and the Surrogate is running on node2, then
migrates it home and confirms it returns.

### Test 2 — Network wormhole (servertestpoll)
Starts a TCP echo server on node1 (port 8080), migrates it to node2, and
verifies the wormhole keeps serving connections on the original node1 IP.

### Test 3 — Pingpong stress
Runs 5 forward+return migration cycles on a single process and verifies it
survives all of them.

### Test 4 — Sustained file I/O across migration (dd_migtest, ~10 min)
Starts a process with a single open fd to a plain file, writing
`os.urandom()`-generated data with an `fsync()` every tick. Migrates it
mid-write and confirms the file keeps growing correctly from the new node
(exercising the ghost-file wormhole's `read`/`write`/`fsync` path directly,
not just process presence), then migrates it back home and confirms the
same. This is the slowest of the four tests (~10 minutes) by design — it
needs sustained I/O on both sides of the migration boundary, not just a
snapshot check immediately after.

### Test 5 — Stale cluster link (`scripts/test-stale-link.sh`, `make test-stale-link-alma`)
Deliberately restarts node2's `mattx` service mid-test to try to recreate a
stale `cluster_map` entry on node1 (a connection the kernel still believes
is live but whose actual TCP socket is gone), then attempts a migration
against it. **Isolated from `test-alma`/Tests 1–4 on purpose**: the
`systemctl restart mattx` this test issues is itself a known crash/hang
trigger on some mattx versions (see `brainmatt/mattx#16`/`#17`), so bundling
it into the default suite risked taking down otherwise-unrelated results.
The script is hardened to survive that: a crash mid-restart is caught,
logged, and waited out (up to ~2 minutes) rather than aborting the whole
run, so you always get a complete report either way.

## DSM (Distributed Shared Memory) Testing

### `scripts/test-dsm.sh` (`make test-dsm-alma`)
Exercises SysV shared-memory (`shmget`/`shmat`/`shmdt`/`shmctl`) migration
using `bin/dsmtest.c` on the standard 2-node cluster: a baseline
no-migration run, a migration mid-loop (exercising the `shmdt`/`shmctl`
wormhole paths), and a migration *before* any SHM syscall fires (forcing
`shmget`/`shmat` through the wormhole too, which the other two scenarios
don't reach).

### `scripts/test-dsm-mesi3.sh` (`make test-dsm-mesi3-alma`, needs `almacluster3`)
A 3-node MESI (`DSM_MODE=2`) coherency regression test, using the upstream
`dsmstresstest-debug` tool (3 workers sharing one SysV SHM segment, each
independently controllable via a `/tmp/<pid>.cmd` file — `write <msg>` /
`read` — for exact, on-demand page-fault triggering instead of relying on
timing). Migrates one worker to each of the 3 nodes and checks that a
write issued by *any* node's worker propagates correctly to the other two
— specifically targeting a gap that doesn't exist in a 2-node topology
(where "the other node" and "the home node" are always the same node).

---

## Test Reports (`reports/`, `scripts/report-table.py`)

Every test script wraps its own run via `auto_report_wrap()` in `lib.sh`:
the full transcript (stdout+stderr, plus a version banner — the exact
mattx git commit and each node's kernel version) is captured to a
timestamped file under `reports/`, e.g. `reports/run-tests-alma-<ts>.txt`.
`reports/` is gitignored — these are per-run artifacts, not checked in.

At the end of every run, `report-table.py` regenerates two summary files
from **every** report currently under `reports/`:

- `reports/run-summary.md` — a plain Markdown table (kernel, commit, label,
  date, result), for quick terminal/PR viewing.
- `reports/run-summary.html` — the same data as a **self-contained,
  interactive page** (no external dependencies, works fine opened directly
  via `file://`): sortable by clicking any column header (defaults to most
  recent run first), and filterable by run type (`run-tests`/`dsm`/
  `stale-link`/etc.) and by result (pass/fail/incomplete) via checkboxes,
  plus a free-text search over kernel/commit.

A report that never reaches its script's own final `Results:` line (e.g.
the run was killed by a crash) is shown as a distinct **"incomplete"**
state rather than being silently counted as a pass.

Regenerate on demand without running any tests: `make report-table`.

---

## EESSI Testing

In addition to the basic migration smoke tests above, the suite can install
[EESSI](https://www.eessi.io/) (the European Environment for Scientific
Software Installations, distributed via CVMFS) on a cluster and run real
scientific-computing workloads — GROMACS and ESPResSo below, with more
EESSI-based workload suites landing incrementally — under MattX migration,
on both AlmaLinux and Debian.

### Setup (`scripts/setup-eessi.sh <alma|deb> <1|2>`)

Run once per node after the cluster is up (`make setup-eessi-alma` /
`make setup-eessi-deb` runs it on both nodes automatically):

1. Installs the CVMFS client (`dnf`/`cvmrepo` RPM on AlmaLinux, `apt`/`.deb`
   on Debian) plus the `cvmfs-config-eessi` package pointing at
   `software.eessi.io`.
2. Writes `/etc/cvmfs/default.local` and runs `cvmfs_config setup`.
3. Explicitly probes `software.eessi.io` (autofs alone only creates the
   mountpoint — an explicit `cvmfs_config probe` is what actually triggers
   the FUSE mount and fetches data) and verifies at least one EESSI version
   directory is visible under `/cvmfs/software.eessi.io/versions/`.
4. If the mount comes up empty, automatically retries with a full
   unmount/remount cycle before failing with CVMFS/autofs/stratum-1
   diagnostics.

### Running the tests (`scripts/test-eessi.sh <alma|deb>`)

`make test-eessi-alma` / `make test-eessi-deb` runs every EESSI workload
suite in `scripts/test-eessi-*.sh` back to back (except the 3-node chain
test below, which needs its own cluster) and prints a combined pass/fail
summary — a suite that fails doesn't stop the others from running. Each
suite can also be run independently:

#### GROMACS (`scripts/test-eessi-gromacs.sh`, `make test-eessi-gromacs-{alma,deb}`)
1. Verify EESSI is mounted and the GROMACS module loads (prefers EESSI
   `2025.06`, falls back to `2023.06` if unavailable).
2. Run the `ion_channel` PRACE benchmark (1000 steps) as a baseline.
3. Start a longer `gmx mdrun`, migrate it node1→node2 via MattX mid-run,
   confirm it's still running, then migrate it back node2→node1 via
   `migrate <pid> home` (issued on the home node) and confirm the round
   trip completes with no kernel oops on either node.
4. **`expel`-based return leg** — a second, independent round trip that
   migrates a fresh `gmx mdrun` forward the same way, then returns it via
   `expel <local-surrogate-pid>` issued *on the node hosting the
   surrogate*, rather than `migrate <pid> home` issued on the home node.
   Both ultimately call the same underlying return-capture code, but this
   exercises the other entry point into it directly, per the maintainer's
   guidance in [brainmatt/mattx#8](https://github.com/brainmatt/mattx/issues/8#issuecomment-5458346309).

#### ESPResSo (`scripts/test-eessi-espresso.sh`, `make test-eessi-espresso-{alma,deb}`)
1. Verify EESSI is mounted and the ESPResSo module loads.
2. Run `plate_capacitor.py` as a functional MPI (2-rank) run.
3. Migrate a single-process ESPResSo job via MattX, returning it home the
   same "recall" way GROMACS Test 3 does.

> **Known gap:** the migration round trip in Test 3 doesn't currently make
> it all the way home. The process resumes and makes real progress after
> the forward leg, but ESPResSo's Open MPI progress engine leans on
> `epoll`/`eventfd` for its own internal event loop, and those don't
> currently survive migration through the wormhole — a real in-kernel
> `epoll` instance and `eventfd` counter can't be transparently
> reconstructed by forwarding individual syscalls one at a time the way
> `open`/`read`/`write`/`fsync` can. GROMACS and the other OpenMP-only/
> single-threaded workloads in this suite are unaffected; this looks
> specific to workloads whose own runtime does its own polling
> (confirmed independently for QuantumESPRESSO's `pw.x` too — same
> signature, no MPI processes involved beyond a single serial rank).

---

## 3-Node Chain Migration (`scripts/test-eessi-gromacs-chain.sh`)

The 2-node round-trip tests above can't tell "the home node" apart from
"the node the job just came from" — with only two nodes, they're the same
node. `make almacluster3` brings up a third AlmaLinux node (`almanode3`)
specifically to close that gap:

```bash
make almacluster3                    # provisions almanode3 on top of the normal 2-node cluster
make test-eessi-gromacs-chain-alma   # node1 -> node2 -> node3 -> node1
```

The test starts a `gmx mdrun` on `almanode1`, forward-migrates it to
`almanode2`, forward-migrates it *again* to `almanode3` (a genuine second
hop, not a bounce back to node1), then recalls it all the way home via
`migrate <pid> home` issued on `almanode1` — checking specifically that the
recall path resolves the *original* exporting node correctly rather than
just the node the job most recently passed through, which a 2-node cluster
structurally cannot exercise.

`almanode3` is deliberately kept out of every other target (`almacluster`,
`test-eessi-alma`, etc.) — the ordinary 2-node AlmaLinux workflow never
provisions or touches it.

See `CHANGELOG.md` for a known bug in this chain (a silent stale-state
resurrection on recall) found while investigating remote-to-remote
migration support.

---

## A `ps` column gotcha worth calling out

Several test scripts print a per-thread snapshot (`show_threads()`) using
`ps -eLo pid,tid,ppid,user,stat,%cpu,wchan:24,cmd`. That last column has to
be `cmd`, never `comm` — the two look interchangeable at a glance (both are
valid `ps` format keywords, both are about "the command"), but they're not
the same thing, and the difference is easy to miss even on a careful read.
Real example, captured live from an actual `gmx mdrun` process (PID 91116):

```
$ ps -eo pid,comm --no-headers | grep gmx
  91116 gmx

$ ps -eo pid,cmd --no-headers | grep gmx
  91116 gmx mdrun -s ion_channel.tpr -nsteps 2000 -ntmpi 1 -ntomp 2 -g /tmp/demo.log
```

`comm` is *only* the executable's own name (`/proc/<pid>/comm`, capped at 15
characters) — never any arguments, no matter how long the field width you
give `ps` is. `cmd` is the full command line, arguments included.

This actually shipped broken for a while: `show_threads()` used `comm`, and
every call site passes a multi-word pattern like `"gmx mdrun"` or
`"pytorch_migtest"` (matched against a script name, not an executable name)
— `mdrun` is an *argument* to the `gmx` binary, not part of its name, so the
`comm` column could never contain it. The check silently printed "no
threads matching" on every single call, whether or not the threads were
actually there, for as long as the code existed — a false negative that
looked exactly like a clean result unless you already knew what a positive
result was supposed to look like. Two people independently reading the
literal `ps` invocation didn't catch it either; it only surfaced by asking
"why does this specific column say `comm` when everything around it treats
this as a full-command match?" Worth remembering next time a `ps` check in
this suite looks like it's not finding something that's clearly there —
check the column list before assuming the process/thread itself is the
problem.

---

## Failure Reference and Manual Reproduction

Set up a shell alias first:
```bash
S="ssh -i test/keys/mattx_test -o StrictHostKeyChecking=no"
```

### Step 0 — Verify cluster state

```bash
$S mattx@192.168.100.21 'cat /proc/mattx/nodes'
```

Expected output shows both nodes with numeric IDs:
```
MattX Cluster Nodes:
Node ID         IP Address      CPU Load  Mem Free (MB)
1 (Local)       192.168.100.21  0         800
2               192.168.100.22  0         800
```

| Failure | Meaning | Check |
|---------|---------|-------|
| `pre-flight: could not determine node ID` | `/proc/mattx/nodes` returned no `(Local)` line — module not loaded or mattx-discd not running | `$S mattx@192.168.100.21 'lsmod \| grep mattx'` |
| `pre-flight: nodeX does not see nodeY` | Discovery hasn't completed — nodes don't know about each other yet | `$S mattx@192.168.100.21 'sudo systemctl status mattx-discd'` and check dmesg for TCP connection messages |

---

### Test 1 — Basic migration: manual steps

```bash
# 1. Get the node IDs (substitute real values below)
NODE1_ID=$($S mattx@192.168.100.21 'awk "/\(Local\)/{print \$1}" /proc/mattx/nodes')
NODE2_ID=$($S mattx@192.168.100.22 'awk "/\(Local\)/{print \$1}" /proc/mattx/nodes')

# 2. Start migtest on debnode1 (watch its log in another terminal)
PID=$($S mattx@192.168.100.21 'migtest &>/tmp/migtest.log & echo $!')

# 3. Migrate forward to node2
$S mattx@192.168.100.21 "echo 'migrate $PID $NODE2_ID' | sudo tee /proc/mattx/admin"

# 4. Verify Deputy on node1 (should show <pid>:<home_node>)
$S mattx@192.168.100.21 'cat /proc/mattx/guests'

# 5. Verify Surrogate on node2
$S mattx@192.168.100.22 'ps aux | grep migtest'

# 6. Recall home
$S mattx@192.168.100.21 "echo 'migrate $PID home' | sudo tee /proc/mattx/admin"

# 7. Confirm process is back on node1
$S mattx@192.168.100.21 'ps aux | grep migtest'

# 8. Clean up
$S mattx@192.168.100.21 "kill $PID 2>/dev/null || true"
```

| Failure | Meaning |
|---------|---------|
| `Deputy missing on node1` | Migration was triggered but the Deputy was never registered — capture failed before the process was frozen, or the module dropped the command (check dmesg on node1 for `[ADMIN]` or `[MIGR]` lines) |
| `migtest not on node2` | The Blueprint was never received or the Surrogate (`mattx-stub`) failed to start on node2 — check dmesg on node2 for `[IMPORT]` lines |
| `migtest not back on node1` | Return migration failed — Deputy is stuck frozen; check dmesg on node1 for `[RETURN]` or `[GUEST]` lines |

---

### Test 2 — Network wormhole: manual steps

```bash
# 1. Start echo server on node1
SERVER_PID=$($S mattx@192.168.100.21 'servertestpoll &>/tmp/server.log & echo $!')

# 2. Confirm reachable before migration
$S mattx@192.168.100.22 'nc -z 192.168.100.21 8080 && echo OK'

# 3. Migrate server to node2
$S mattx@192.168.100.21 "echo 'migrate $SERVER_PID $NODE2_ID' | sudo tee /proc/mattx/admin"
sleep 5

# 4. Confirm Surrogate on node2
$S mattx@192.168.100.22 'ps aux | grep servertestpoll'

# 5. Confirm wormhole: connect to node1's IP — traffic proxies to node2
$S mattx@192.168.100.22 'nc -z 192.168.100.21 8080 && echo wormhole OK'

# 6. Clean up
$S mattx@192.168.100.21 "kill $SERVER_PID 2>/dev/null || true"
```

| Failure | Meaning |
|---------|---------|
| `servertestpoll not on node2` | Migration failed — see Test 1 failures above |
| `wormhole broken` | Process migrated but the ghost-file `recv`/`send` kretprobes aren't routing traffic back to node1 — check dmesg on node2 for `[WORMHOLE]` or `[FILEIO]` lines |

---

### Watching the kernel log live

Open a second terminal while running tests:
```bash
ssh -i test/keys/mattx_test mattx@192.168.100.21 'sudo dmesg -w'
ssh -i test/keys/mattx_test mattx@192.168.100.22 'sudo dmesg -w'
```

Enable verbose debug logging to see every migration step:
```bash
$S mattx@192.168.100.21 "echo 'debug 1' | sudo tee /proc/mattx/admin"
$S mattx@192.168.100.22 "echo 'debug 1' | sudo tee /proc/mattx/admin"
```

### Getting a real kernel backtrace on a crash/hang (kdump)

A crashed or hung `mattx.ko` load often produces **nothing** on the guest's
serial console — confirmed the hard way (repeated console-read attempts
during a live hang, including one starting 6+ minutes in, well past the
kernel's own hung-task watchdog: zero bytes captured). If a node stops
responding, `dmesg`/`virsh console`/SSH after the fact won't show you
anything either, since the crash already took the console down with it.
kdump is the actual fix for this: a real oops/panic (as opposed to a hard
hang with no oops at all — kdump can't help with that specific case, only
with genuine kernel faults) boots a small reserved-memory crash kernel and
writes the full crashed kernel's memory to `/var/crash` on the guest
*before* it reboots.

`setup-node.sh` enables this automatically on every AlmaLinux node as part
of its normal provisioning (`kexec-tools` + `kdump-utils` + `makedumpfile`
installed — `kexec-tools` alone is just the low-level `kexec`/
`vmcore-dmesg` binaries on RHEL 10, `kdumpctl`/`kdump.service`/
`/etc/kdump.conf` come from `kdump-utils` — plus `crashkernel=192M` added
to the boot line and `kdump.service` enabled, all piggybacked onto the
reboot that provisioning already does, so it costs nothing extra). Not yet
done for Debian/Ubuntu nodes (different tooling — `kdump-tools`, not
`kexec-tools`/`kdump-utils` — and untested; PRs welcome).

**Quick manual setup on any AlmaLinux/RHEL 10 box** (not tied to this test
harness — this is the exact sequence `setup-node.sh` runs, standalone):
```bash
sudo dnf install -y kexec-tools kdump-utils makedumpfile
sudo grubby --update-kernel=ALL --args='crashkernel=192M'
sudo reboot   # crash-kernel memory is only reserved at boot time

# after reboot:
grep -q crashkernel /proc/cmdline && echo "crashkernel reservation active"
sudo systemctl enable --now kdump
sudo kdumpctl status   # expect: "Kdump is operational"
```
`192M` is comfortable for a 2GB VM; bump it for a bigger box if
`kdumpctl status` complains about insufficient reserved memory. Crash
dumps land in `/var/crash/<timestamp>/` on the crashed host itself —
`vmcore` (the full memory image) plus an auto-extracted `vmcore-dmesg.txt`
(just the crash's dmesg buffer, usually enough on its own without needing
`crash` + matching debuginfo).

After a crash, fetch whatever landed in `/var/crash`:
```bash
scripts/fetch-crash-dump.sh alma 1   # or 2, or 3
```
This lists what's there and rsyncs it into `test/crash-dumps/<node>-<timestamp>/`
(gitignored — these can be sizable and are inherently local/ephemeral).
Each crash directory includes a `vmcore-dmesg.txt` — just the crash's
dmesg buffer, extracted automatically — which is usually enough to see the
actual oops/panic without needing the full `crash` debugger and a matching
debuginfo kernel:
```bash
cat test/crash-dumps/almanode1-*/vmcore-dmesg.txt
```

Sanity-check kdump is actually live on a node at any time with:
```bash
$S mattx@192.168.100.11 "sudo kdumpctl status"
```

---

## Disk Layout

Base images and VM disks live in separate directories so that `make clean`
can safely wipe VM state without re-downloading anything.

```
/var/lib/libvirt/images/mattx-base/   ← never touched by make clean
├── almalinux-10-base.qcow2           # ~600 MB, downloaded once
└── debian-13-base.qcow2              # ~300 MB, downloaded once

/var/lib/libvirt/images/mattx-test/   ← wiped by make clean-{alma,deb}
├── almanode1.qcow2                   # thin qcow2 clone, 10 GB sparse
├── almanode1-seed.iso                # cloud-init NoCloud seed
├── almanode2.qcow2
├── almanode2-seed.iso
├── debnode1.qcow2
├── debnode1-seed.iso
├── debnode2.qcow2
└── debnode2-seed.iso
```

The download uses `curl -C -` (resume on restart), so an interrupted download
won't restart from zero. If a `.tmp` file is left behind by a crash, remove it
and re-run — the intact base image will be detected and skipped.

To purge the base image cache entirely:
```bash
sudo rm -rf /var/lib/libvirt/images/mattx-base/
```






All bugs produced by CLAUDE.
