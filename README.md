# MattX Automated Test Suite


Put this repository as a submodule in your MattX  test/ project.

This is meant to easily spin up a test environment that allows you to test MattX






Fully automated 2-node cluster provisioning and migration smoke tests for
[MattX](../README.md), targeting Debian 13 (trixie), Ubuntu 26.04 and AlmaLinux 10.

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
| Debian node 1 | `debnode1` | 192.168.100.21 |
| Debian node 2 | `debnode2` | 192.168.100.22 |
| Ubuntu node 1 | `ubunode1` | 192.168.100.31 |
| Ubuntu node 2 | `ubunode2` | 192.168.100.32 |

All VMs share the `mattx-test` libvirt NAT network (192.168.100.0/24).
IPs are fixed via MAC→IP DHCP reservations. Nodes can reach each other
and have internet access via NAT through the host.

---

## Make Targets

```
make alma          Provision single AlmaLinux 10 node (almanode1)
make debian        Provision single Debian 13 node   (debnode1)
make ubuntu        Provision single Ubuntu 26.04 node   (ubunode1)
make almacluster   2-node AlmaLinux cluster: provision + build + deploy MattX
make debcluster    2-node Debian cluster:    provision + build + deploy MattX
make ubucluster    2-node Ubuntu cluster:    provision + build + deploy MattX
make allclusters   All clusters (use -j3 to run in parallel)
make test-alma     Run migration smoke tests on AlmaLinux cluster
make test-deb      Run migration smoke tests on Debian cluster
make test-ubu      Run migration smoke tests on Ubuntu cluster
make setup-eessi-alma          Install CVMFS + EESSI on AlmaLinux cluster
make setup-eessi-deb           Install CVMFS + EESSI on Debian cluster
make test-eessi-alma           Run full EESSI test suite (ESPResSo + GROMACS) on AlmaLinux
make test-eessi-deb            Run full EESSI test suite (ESPResSo + GROMACS) on Debian
make test-eessi-gromacs-alma   Run only the GROMACS EESSI tests on AlmaLinux
make test-eessi-gromacs-deb    Run only the GROMACS EESSI tests on Debian
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

---

## EESSI Testing

In addition to the basic migration smoke tests above, the suite can install
[EESSI](https://www.eessi.io/) (the European Environment for Scientific
Software Installations, distributed via CVMFS) on a cluster and run real
scientific-computing workloads — GROMACS and ESPResSo — under MattX
migration, on both AlmaLinux and Debian.

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

`make test-eessi-alma` / `make test-eessi-deb` runs both suites back to back
and prints a combined pass/fail summary. Each can also be run independently:

#### GROMACS (`scripts/test-eessi-gromacs.sh`, `make test-eessi-gromacs-{alma,deb}`)
1. Verify EESSI is mounted and the GROMACS module loads (prefers EESSI
   `2025.06`, falls back to `2023.06` if unavailable).
2. Run the `ion_channel` PRACE benchmark (1000 steps) as a baseline.
3. Start a longer `gmx mdrun`, migrate it node1→node2 via MattX mid-run,
   confirm it's still running, then migrate it back node2→node1 and confirm
   the round trip completes with no kernel oops on either node.

#### ESPResSo (`scripts/test-eessi-espresso.sh`, `make test-eessi-espresso-{alma,deb}`)
1. Verify EESSI is mounted and the ESPResSo module loads.
2. Run `plate_capacitor.py` as a functional MPI (2-rank) run.
3. Migrate a single-process ESPResSo job via MattX.

> **Known gap:** Test 2 of the ESPResSo suite currently fails with `rsync
> failed` — the `eessi-demo/ESPResSo/` directory it expects doesn't exist in
> this repo checkout and no setup step creates it. This reproduces the same
> way on both AlmaLinux and Debian, so it's a test-suite packaging gap
> rather than a distro- or MattX-specific issue. GROMACS is unaffected.

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
