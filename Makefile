export LIBVIRT_DEFAULT_URI := qemu:///system
SCRIPTS  := scripts
STAMP    := .stamp
KEYS_DIR := keys
# where the VM disks live (not / : the overlays grow to several GB each)
IMAGES_ROOT ?= /opt/libvirt-images
export MATTX_IMAGES_ROOT := $(IMAGES_ROOT)

# Fixed IPs for reference
# almanode1: 192.168.100.11   almanode2: 192.168.100.12   almanode3: 192.168.100.13 (chain-migration tests only)
# debnode1:  192.168.100.21   debnode2:  192.168.100.22
# ubunode1:  192.168.100.31   ubunode2:  192.168.100.32

.PHONY: fedora fedcluster upgrade-fed start-fed test-fed all alma debian ubuntu almacluster almacluster3 debcluster ubucluster allclusters \
        upgrade-alma upgrade-alma3 upgrade-deb upgrade-ubu \
        test-alma test-deb test-ubu ensure-alma-running ensure-alma-running3 ensure-deb-running \
        setup-eessi-alma setup-eessi-alma3 setup-eessi-deb setup-eessi-ubu \
        test-eessi-alma test-eessi-deb test-eessi-ubu \
        test-eessi-espresso-alma test-eessi-espresso-deb test-eessi-espresso-ubu \
        test-eessi-gromacs-alma test-eessi-gromacs-deb test-eessi-gromacs-ubu \
        test-eessi-gromacs-chain-alma test-eessi-gromacs-chain-alma-mattx-admin \
        test-eessi-gromacs-relay-alma test-eessi-gromacs-relay-alma-mattx-admin \
        test-eessi-quantumespresso-alma test-eessi-quantumespresso-deb test-eessi-quantumespresso-ubu \
        test-eessi-openfoam-alma test-eessi-openfoam-deb test-eessi-openfoam-ubu \
        test-eessi-pytorch-alma test-eessi-pytorch-deb test-eessi-pytorch-ubu \
        test-eessi-pytorch-mp-alma test-eessi-pytorch-mp-deb test-eessi-pytorch-mp-ubu \
        test-eessi-tensorflow-alma test-eessi-tensorflow-deb test-eessi-tensorflow-ubu \
        test-eessi-bioconductor-alma test-eessi-bioconductor-deb test-eessi-bioconductor-ubu \
        test-eessi-nextflow-alma test-eessi-nextflow-deb test-eessi-nextflow-ubu \
        test-eessi-osu-shm-alma test-eessi-osu-shm-deb test-eessi-osu-shm-ubu \
        test-mpi-alma test-mpi-deb test-mpi-ubu test-mpi-nompi-alma test-mpi-nompi-ubu test-mpi-fed test-mpi-nompi-fed test-unload-active-alma \
        test-dsm-alma test-dsm-deb test-dsm-ubu test-dsm-mesi3-alma \
        test-stale-link-alma test-stale-link-deb test-stale-link-ubu test-unload-alma test-mattxfs-umount-alma test-admin-input-alma \
        start-alma start-alma3 start-deb start-ubu start \
        stop-alma stop-deb stop-ubu stop-fed stop \
        status \
        clean-alma clean-deb clean-ubu clean \
        report-table \
        keys check setup

all:
	@echo "First-time setup (run once, requires sudo):"
	@echo "  make setup         add $(USER) to libvirt group + grant image dir access"
	@echo ""
	@echo "Provisioning:"
	@echo "  make alma          provision single AlmaLinux 10 node (almanode1)"
	@echo "  make debian        provision single Debian 13 node   (debnode1)"
	@echo "  make ubuntu        provision single Ubuntu 26.04 node (ubunode1)"
	@echo "  make fedora        provision single Fedora 44 node (fednode1)"
	@echo "  make almacluster   2-node AlmaLinux cluster: provision + build + start MattX"
	@echo "  make almacluster3  3-node AlmaLinux cluster: adds almanode3 for chain-migration tests"
	@echo "  make debcluster    2-node Debian cluster:    provision + build + start MattX"
	@echo "  make ubucluster    2-node Ubuntu cluster:    provision + build + start MattX"
	@echo "  make fedcluster    2-node Fedora 44 cluster (kernel 7.2): provision + build + start MattX"
	@echo "  make allclusters   both clusters"
	@echo ""
	@echo "Daily use (VMs stay on disk, no reprovisioning):"
	@echo "  make stop          graceful shutdown of all VMs"
	@echo "  make stop-alma     graceful shutdown of AlmaLinux VMs"
	@echo "  make stop-deb      graceful shutdown of Debian VMs"
	@echo "  make stop-ubu      graceful shutdown of Ubuntu VMs"
	@echo "  make stop-fed      graceful shutdown of Fedora VMs"
	@echo "  make start         start all VMs + restart MattX"
	@echo "  make start-alma    start AlmaLinux VMs + restart MattX"
	@echo "  make start-deb     start Debian VMs + restart MattX"
	@echo "  make start-ubu     start Ubuntu VMs + restart MattX"
	@echo "  make start-fed     start Fedora VMs + restart MattX"
	@echo "  make status        show VM power states"
	@echo ""
	@echo "Upgrade (rebuild + reload on running cluster):"
	@echo "  make upgrade-alma  rebuild MattX and reload modules on AlmaLinux cluster"
	@echo "  make upgrade-deb   rebuild MattX and reload modules on Debian cluster"
	@echo "  make upgrade-ubu   rebuild MattX and reload modules on Ubuntu cluster"
	@echo "  make upgrade-fed   rebuild MattX and reload modules on Fedora cluster"
	@echo ""
	@echo "Testing:"
	@echo "  make test-alma               run MattX migration tests on AlmaLinux cluster"
	@echo "  make test-deb                run MattX migration tests on Debian cluster"
	@echo "  make test-ubu                run MattX migration tests on Ubuntu cluster"
	@echo "  make test-fed                run MattX migration tests on Fedora cluster"
	@echo ""
	@echo "EESSI / HPC software stack:"
	@echo "  make setup-eessi-alma        install CVMFS + EESSI on AlmaLinux cluster"
	@echo "  make setup-eessi-deb         install CVMFS + EESSI on Debian cluster"
	@echo "  make setup-eessi-ubu         install CVMFS + EESSI on Ubuntu cluster"
	@echo "  make test-eessi-alma         run full EESSI test suite on AlmaLinux cluster"
	@echo "  make test-eessi-deb          run full EESSI test suite on Debian cluster"
	@echo "  make test-eessi-ubu          run full EESSI test suite on Ubuntu cluster"
	@echo "  make test-eessi-espresso-alma  run ESPResSo tests on AlmaLinux cluster"
	@echo "  make test-eessi-espresso-deb   run ESPResSo tests on Debian cluster"
	@echo "  make test-eessi-espresso-ubu   run ESPResSo tests on Ubuntu cluster"
	@echo "  make test-eessi-gromacs-alma   run GROMACS tests on AlmaLinux cluster"
	@echo "  make test-eessi-gromacs-deb    run GROMACS tests on Debian cluster"
	@echo "  make test-eessi-gromacs-ubu    run GROMACS tests on Ubuntu cluster"
	@echo "  make test-eessi-gromacs-chain-alma  run 3-node GROMACS chain migration (node1->2->3->1)"
	@echo ""
	@echo "Destruction (deletes disks — requires full reprovision):"
	@echo "  make clean-alma    destroy AlmaLinux VMs and disks"
	@echo "  make clean-deb     destroy Debian VMs and disks"
	@echo "  make clean-ubu     destroy Ubuntu VMs and disks"
	@echo ""
	@echo "Provisioning is idempotent: re-running skips completed steps."

setup:
	@echo "[setup] configuring host for passwordless libvirt access..."
	@if ! id -nG | tr ' ' '\n' | grep -qx libvirt; then \
	    sudo usermod -aG libvirt $(USER); \
	    echo "[setup] added $(USER) to libvirt group"; \
	else \
	    echo "[setup] $(USER) already in libvirt group"; \
	fi
	@test -d $(IMAGES_ROOT) || sudo install -d -m 2775 -g libvirt $(IMAGES_ROOT)
	@if ! test -w $(IMAGES_ROOT)/; then \
	    sudo setfacl -m u:$(USER):rwx $(IMAGES_ROOT)/ 2>/dev/null || \
	    sudo chmod g+rwx $(IMAGES_ROOT)/; \
	    echo "[setup] granted write access to $(IMAGES_ROOT)/"; \
	fi
	@echo "[setup] done"
	@id -nG | tr ' ' '\n' | grep -qx libvirt || \
	    echo "[setup] NOTE: run 'newgrp libvirt' or log out/in to activate the libvirt group"

check:
	@command -v virsh        >/dev/null || { echo "ERROR: virsh not found (install libvirt)"; exit 1; }
	@command -v virt-install >/dev/null || { echo "ERROR: virt-install not found"; exit 1; }
	@command -v qemu-img     >/dev/null || { echo "ERROR: qemu-img not found"; exit 1; }
	@command -v rsync        >/dev/null || { echo "ERROR: rsync not found"; exit 1; }
	@command -v curl         >/dev/null || { echo "ERROR: curl not found"; exit 1; }
	@{ command -v cloud-localds || command -v genisoimage || command -v mkisofs; } \
		>/dev/null 2>&1 || \
		{ echo "ERROR: need cloud-localds, genisoimage, or mkisofs"; exit 1; }
	@id -nG | tr ' ' '\n' | grep -qx libvirt || \
		{ echo "ERROR: $(USER) is not in the libvirt group — run: make setup"; exit 1; }
	@test -w $(IMAGES_ROOT)/ || \
		{ echo "ERROR: cannot write to $(IMAGES_ROOT)/ — run: make setup"; exit 1; }

keys: $(KEYS_DIR)/mattx_test

$(KEYS_DIR)/mattx_test:
	@mkdir -p $(KEYS_DIR)
	ssh-keygen -t ed25519 -N "" -C "mattx-test" -f $@
	@echo "[keys] generated $@"

$(STAMP):
	@mkdir -p $@

# ---- libvirt network (all 4 MAC→IP reservations in one shot) ----

$(STAMP)/network: | check $(STAMP)
	$(SCRIPTS)/ensure-libvirt-network.sh mattx-test 192.168.100.1 mattxbr0 \
		52:54:00:0a:00:11=192.168.100.11 \
		52:54:00:0a:00:12=192.168.100.12 \
		52:54:00:0a:00:13=192.168.100.13 \
		52:54:00:0b:00:21=192.168.100.21 \
		52:54:00:0b:00:22=192.168.100.22 \
		52:54:00:0b:00:31=192.168.100.31 \
		52:54:00:0b:00:32=192.168.100.32 \
		52:54:00:0c:00:41=192.168.100.41 \
		52:54:00:0c:00:42=192.168.100.42
	@touch $@

# ---- VM provisioning ----

$(STAMP)/alma-vms: $(STAMP)/network | keys
	$(SCRIPTS)/create-vm.sh alma 1
	$(SCRIPTS)/create-vm.sh alma 2
	$(SCRIPTS)/setup-node.sh alma 1
	$(SCRIPTS)/setup-node.sh alma 2
	@touch $@

# 3rd AlmaLinux node, for chain-migration tests only (node1 -> node2 ->
# node3 -> node1). Kept separate from alma-vms so the ordinary 2-node alma
# workflow never provisions a VM it doesn't need.
$(STAMP)/alma-vms3: $(STAMP)/alma-vms
	$(SCRIPTS)/create-vm.sh alma 3
	$(SCRIPTS)/setup-node.sh alma 3
	@touch $@

$(STAMP)/deb-vms: $(STAMP)/network | keys
	$(SCRIPTS)/create-vm.sh deb 1
	$(SCRIPTS)/create-vm.sh deb 2
	$(SCRIPTS)/setup-node.sh deb 1
	$(SCRIPTS)/setup-node.sh deb 2
	@touch $@

$(STAMP)/ubu-vms: $(STAMP)/network | keys
	$(SCRIPTS)/create-vm.sh ubu 1
	$(SCRIPTS)/create-vm.sh ubu 2
	$(SCRIPTS)/setup-node.sh ubu 1
	$(SCRIPTS)/setup-node.sh ubu 2
	@touch $@

# ---- Build & deploy MattX ----

$(STAMP)/alma-built: $(STAMP)/alma-vms
	$(SCRIPTS)/build-mattx.sh alma
	@touch $@

$(STAMP)/deb-built: $(STAMP)/deb-vms
	$(SCRIPTS)/build-mattx.sh deb
	@touch $@

$(STAMP)/ubu-built: $(STAMP)/ubu-vms
	$(SCRIPTS)/build-mattx.sh ubu
	@touch $@

# Fedora 44 (kernel 7.2): fednode1/2, 192.168.100.41/42
$(STAMP)/fed-vms: $(STAMP)/network | keys
	$(SCRIPTS)/create-vm.sh fed 1
	$(SCRIPTS)/create-vm.sh fed 2
	$(SCRIPTS)/setup-node.sh fed 1
	$(SCRIPTS)/setup-node.sh fed 2
	@touch $@

$(STAMP)/fed-built: $(STAMP)/fed-vms
	$(SCRIPTS)/build-mattx.sh fed
	@touch $@

$(STAMP)/fed-deployed: $(STAMP)/fed-built
	$(SCRIPTS)/deploy-mattx.sh fed
	@touch $@

fedcluster: $(STAMP)/fed-deployed
	$(SCRIPTS)/start-mattx.sh fed 1
	$(SCRIPTS)/start-mattx.sh fed 2
	@echo "Fedora cluster ready: fednode1 192.168.100.41, fednode2 192.168.100.42"

upgrade-fed:
	$(SCRIPTS)/build-mattx.sh fed
	$(SCRIPTS)/deploy-mattx.sh fed
	$(SCRIPTS)/start-mattx.sh fed 1
	$(SCRIPTS)/start-mattx.sh fed 2

start-fed:
	virsh start fednode1 2>/dev/null || true
	virsh start fednode2 2>/dev/null || true
	$(SCRIPTS)/setup-node.sh fed 1
	$(SCRIPTS)/setup-node.sh fed 2
	$(SCRIPTS)/start-mattx.sh fed 1
	$(SCRIPTS)/start-mattx.sh fed 2

test-fed: start-fed
	$(SCRIPTS)/run-tests.sh fed

$(STAMP)/alma-deployed: $(STAMP)/alma-built
	$(SCRIPTS)/deploy-mattx.sh alma
	@touch $@

# 3rd node's build/deploy, layered on top of the normal 2-node ones -- node1
# is already built by alma-built; this just also deploys to almanode3.
$(STAMP)/alma-deployed3: $(STAMP)/alma-deployed $(STAMP)/alma-vms3
	$(SCRIPTS)/deploy-mattx.sh alma almanode3
	@touch $@

$(STAMP)/deb-deployed: $(STAMP)/deb-built
	$(SCRIPTS)/deploy-mattx.sh deb
	@touch $@

$(STAMP)/ubu-deployed: $(STAMP)/ubu-built
	$(SCRIPTS)/deploy-mattx.sh ubu
	@touch $@

# ---- High-level targets ----

alma: $(STAMP)/network keys
	$(SCRIPTS)/create-vm.sh alma 1
	$(SCRIPTS)/setup-node.sh alma 1
	@echo ""
	@echo "AlmaLinux node ready — ssh mattx@192.168.100.11 -i $(KEYS_DIR)/mattx_test"

debian: $(STAMP)/network keys
	$(SCRIPTS)/create-vm.sh deb 1
	$(SCRIPTS)/setup-node.sh deb 1
	@echo ""
	@echo "Debian node ready — ssh mattx@192.168.100.21 -i $(KEYS_DIR)/mattx_test"

ubuntu: $(STAMP)/network keys
	$(SCRIPTS)/create-vm.sh ubu 1
	$(SCRIPTS)/setup-node.sh ubu 1
	@echo ""
	@echo "Ubuntu node ready — ssh mattx@192.168.100.31 -i $(KEYS_DIR)/mattx_test"

fedora: $(STAMP)/network keys
	$(SCRIPTS)/create-vm.sh fed 1
	$(SCRIPTS)/setup-node.sh fed 1
	@echo ""
	@echo "Fedora node ready — ssh mattx@192.168.100.41 -i $(KEYS_DIR)/mattx_test"

almacluster: $(STAMP)/alma-deployed
	$(SCRIPTS)/start-mattx.sh alma 1
	$(SCRIPTS)/start-mattx.sh alma 2
	@echo ""
	@echo "AlmaLinux cluster ready:"
	@echo "  almanode1: 192.168.100.11"
	@echo "  almanode2: 192.168.100.12"
	@echo "  ssh mattx@192.168.100.11 -i $(KEYS_DIR)/mattx_test"

# 3-node AlmaLinux cluster, for chain-migration tests (node1 -> node2 ->
# node3 -> node1). Brings up node3 in addition to the normal 2-node cluster.
# Depends on ensure-alma-running (not almacluster/start-mattx.sh) for nodes
# 1/2 -- start-mattx.sh's unconditional rmmod/insmod reload is unsafe on a
# cluster that's already up and connected (mt-985.2 / mt-463); node3 itself
# is safe via start-mattx.sh since it's freshly provisioned and was never
# connected to anything yet.
almacluster3: ensure-alma-running $(STAMP)/alma-deployed3
	$(SCRIPTS)/start-mattx.sh alma 3
	@echo ""
	@echo "AlmaLinux 3-node cluster ready:"
	@echo "  almanode1: 192.168.100.11"
	@echo "  almanode2: 192.168.100.12"
	@echo "  almanode3: 192.168.100.13"
	@echo "  ssh mattx@192.168.100.11 -i $(KEYS_DIR)/mattx_test"

debcluster: $(STAMP)/deb-deployed
	$(SCRIPTS)/start-mattx.sh deb 1
	$(SCRIPTS)/start-mattx.sh deb 2
	@echo ""
	@echo "Debian cluster ready:"
	@echo "  debnode1: 192.168.100.21"
	@echo "  debnode2: 192.168.100.22"
	@echo "  ssh mattx@192.168.100.21 -i $(KEYS_DIR)/mattx_test"

ubucluster: $(STAMP)/ubu-deployed
	$(SCRIPTS)/start-mattx.sh ubu 1
	$(SCRIPTS)/start-mattx.sh ubu 2
	@echo ""
	@echo "Ubuntu cluster ready:"
	@echo "  ubunode1: 192.168.100.31"
	@echo "  ubunode2: 192.168.100.32"
	@echo "  ssh mattx@192.168.100.31 -i $(KEYS_DIR)/mattx_test"

allclusters: almacluster debcluster ubucluster

# ---- Upgrade (rebuild + reload on running cluster, no reprovisioning) ----

upgrade-alma:
	$(SCRIPTS)/build-mattx.sh alma
	$(SCRIPTS)/deploy-mattx.sh alma
	$(SCRIPTS)/start-mattx.sh alma 1
	$(SCRIPTS)/start-mattx.sh alma 2

upgrade-alma3: upgrade-alma
	$(SCRIPTS)/deploy-mattx.sh alma almanode3
	$(SCRIPTS)/start-mattx.sh alma 3

upgrade-deb:
	$(SCRIPTS)/build-mattx.sh deb
	$(SCRIPTS)/deploy-mattx.sh deb
	$(SCRIPTS)/start-mattx.sh deb 1
	$(SCRIPTS)/start-mattx.sh deb 2

upgrade-ubu:
	$(SCRIPTS)/build-mattx.sh ubu
	$(SCRIPTS)/deploy-mattx.sh ubu
	$(SCRIPTS)/start-mattx.sh ubu 1
	$(SCRIPTS)/start-mattx.sh ubu 2

# ---- Test targets ----

# NOTE: test-* deliberately do NOT depend on start-alma/start-deb. Those force
# a live rmmod/insmod reload, which is unsafe on a cluster that's already up
# and connected (crashes mattx.ko — see mt-985.2 / mt-463). ensure-*-running
# only reloads a node that isn't already healthy; a genuinely fresh/stopped
# node has no stale peer state, so reloading it is safe.
ensure-alma-running:
	virsh start almanode1 2>/dev/null || true
	virsh start almanode2 2>/dev/null || true
	$(SCRIPTS)/ensure-mattx-running.sh alma 1
	$(SCRIPTS)/ensure-mattx-running.sh alma 2

ensure-alma-running3: ensure-alma-running
	virsh start almanode3 2>/dev/null || true
	$(SCRIPTS)/ensure-mattx-running.sh alma 3

ensure-deb-running:
	virsh start debnode1 2>/dev/null || true
	virsh start debnode2 2>/dev/null || true
	$(SCRIPTS)/ensure-mattx-running.sh deb 1
	$(SCRIPTS)/ensure-mattx-running.sh deb 2

test-alma: ensure-alma-running
	$(SCRIPTS)/run-tests.sh alma

test-dsm-alma: ensure-alma-running
	$(SCRIPTS)/test-dsm.sh alma

test-dsm-mesi3-alma: ensure-alma-running3
	$(SCRIPTS)/test-dsm-mesi3.sh alma

test-dsm-deb: ensure-deb-running
	$(SCRIPTS)/test-dsm.sh deb

test-dsm-ubu: start-ubu
	$(SCRIPTS)/test-dsm.sh ubu

test-stale-link-alma: ensure-alma-running
	$(SCRIPTS)/test-stale-link.sh alma

test-unload-alma: ensure-alma-running
	$(SCRIPTS)/test-unload.sh alma

test-mattxfs-umount-alma: ensure-alma-running
	$(SCRIPTS)/test-mattxfs-umount.sh alma

test-admin-input-alma: ensure-alma-running
	$(SCRIPTS)/test-admin-input.sh alma

test-threads-alma: ensure-alma-running
	$(SCRIPTS)/test-threads.sh alma

test-epoll-threads-alma: ensure-alma-running
	$(SCRIPTS)/test-epoll-threads.sh alma

test-stale-link-deb: ensure-deb-running
	$(SCRIPTS)/test-stale-link.sh deb

test-stale-link-ubu: start-ubu
	$(SCRIPTS)/test-stale-link.sh ubu

test-deb: ensure-deb-running
	$(SCRIPTS)/run-tests.sh deb

test-ubu: start-ubu
	$(SCRIPTS)/run-tests.sh ubu

# ---- EESSI setup (idempotent via stamps) ----

$(STAMP)/alma-eessi: $(STAMP)/alma-vms
	$(SCRIPTS)/setup-eessi.sh alma 1
	$(SCRIPTS)/setup-eessi.sh alma 2
	@touch $@

$(STAMP)/alma-eessi3: $(STAMP)/alma-eessi $(STAMP)/alma-deployed3
	$(SCRIPTS)/setup-eessi.sh alma 3
	@touch $@

$(STAMP)/deb-eessi: $(STAMP)/deb-vms
	$(SCRIPTS)/setup-eessi.sh deb 1
	$(SCRIPTS)/setup-eessi.sh deb 2
	@touch $@

$(STAMP)/ubu-eessi: $(STAMP)/ubu-vms
	$(SCRIPTS)/setup-eessi.sh ubu 1
	$(SCRIPTS)/setup-eessi.sh ubu 2
	@touch $@

setup-eessi-alma: $(STAMP)/alma-eessi

setup-eessi-alma3: $(STAMP)/alma-eessi3

setup-eessi-deb: $(STAMP)/deb-eessi

setup-eessi-ubu: $(STAMP)/ubu-eessi

# ---- EESSI test targets ----

test-eessi-espresso-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-espresso.sh alma

test-eessi-espresso-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-espresso.sh deb

test-eessi-espresso-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-espresso.sh ubu

test-eessi-gromacs-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-gromacs.sh alma

test-eessi-gromacs-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-gromacs.sh deb

test-eessi-gromacs-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-gromacs.sh ubu

test-eessi-gromacs-chain-alma: ensure-alma-running3 $(STAMP)/alma-eessi3
	$(SCRIPTS)/test-eessi-gromacs-chain.sh alma

# Same chain test, but issuing every migration through the upstream
# mattx-admin CLI instead of a raw `echo > /proc/mattx/admin` write. See
# CHANGELOG.md "Known Issues" -- confirmed live that mattx-admin does NOT
# refuse Leg 2 (the unsupported node2 -> node3 direct hop) either; its
# "already migrated" guard has a blind spot for this case, so both tools
# corrupt state here today. Every MATTX_TOOL-aware script in this suite
# accepts this same env var.
test-eessi-gromacs-chain-alma-mattx-admin: ensure-alma-running3 $(STAMP)/alma-eessi3
	MATTX_TOOL=mattx-admin $(SCRIPTS)/test-eessi-gromacs-chain.sh alma

# The OTHER way to move a job across three nodes: never hop remote-to-remote
# directly -- always recall home first, then migrate again from home. Every
# individual hop here is home<->remote (the same shape test-eessi-gromacs.sh
# already validates), so this is expected to actually work, unlike the
# direct chain above. Confirmed live: it does -- see CHANGELOG.md.
test-eessi-gromacs-relay-alma: ensure-alma-running3 $(STAMP)/alma-eessi3
	$(SCRIPTS)/test-eessi-gromacs-relay.sh alma

test-eessi-gromacs-relay-alma-mattx-admin: ensure-alma-running3 $(STAMP)/alma-eessi3
	MATTX_TOOL=mattx-admin $(SCRIPTS)/test-eessi-gromacs-relay.sh alma

test-eessi-quantumespresso-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-quantumespresso.sh alma

test-eessi-quantumespresso-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-quantumespresso.sh deb

test-eessi-quantumespresso-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-quantumespresso.sh ubu

test-eessi-openfoam-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-openfoam.sh alma

test-eessi-openfoam-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-openfoam.sh deb

test-eessi-openfoam-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-openfoam.sh ubu

test-eessi-pytorch-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-pytorch.sh alma

test-eessi-pytorch-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-pytorch.sh deb

test-eessi-pytorch-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-pytorch.sh ubu

test-eessi-pytorch-mp-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-pytorch-mp.sh alma

test-eessi-pytorch-mp-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-pytorch-mp.sh deb

test-eessi-pytorch-mp-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-pytorch-mp.sh ubu

test-eessi-bioconductor-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-bioconductor.sh alma

test-eessi-bioconductor-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-bioconductor.sh deb

test-eessi-bioconductor-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-bioconductor.sh ubu

test-eessi-tensorflow-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-tensorflow.sh alma

test-eessi-tensorflow-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-tensorflow.sh deb

test-eessi-tensorflow-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-tensorflow.sh ubu

test-eessi-nextflow-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-nextflow.sh alma

test-eessi-nextflow-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-nextflow.sh deb

test-eessi-nextflow-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-nextflow.sh ubu

test-eessi-osu-shm-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi-osu-shm.sh alma

test-eessi-osu-shm-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi-osu-shm.sh deb

test-eessi-osu-shm-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi-osu-shm.sh ubu

test-mpi-alma: ensure-alma-running
	$(SCRIPTS)/test-mpi.sh alma

test-mpi-deb: ensure-deb-running
	$(SCRIPTS)/test-mpi.sh deb

test-mpi-ubu: start-ubu
	$(SCRIPTS)/test-mpi.sh ubu

test-unload-active-alma: ensure-alma-running
	$(SCRIPTS)/test-unload-active.sh alma

test-mpi-fed: start-fed
	$(SCRIPTS)/test-mpi.sh fed

test-mpi-nompi-fed: start-fed
	MPI_SUPPORT=0 $(SCRIPTS)/test-mpi.sh fed

test-mpi-nompi-alma: ensure-alma-running
	MPI_SUPPORT=0 $(SCRIPTS)/test-mpi.sh alma

test-mpi-nompi-ubu: start-ubu
	MPI_SUPPORT=0 $(SCRIPTS)/test-mpi.sh ubu

test-eessi-alma: $(STAMP)/alma-eessi
	$(SCRIPTS)/test-eessi.sh alma

test-eessi-deb: $(STAMP)/deb-eessi
	$(SCRIPTS)/test-eessi.sh deb

test-eessi-ubu: $(STAMP)/ubu-eessi
	$(SCRIPTS)/test-eessi.sh ubu

# ---- Stop (graceful shutdown, VMs and disks preserved) ----

stop-alma:
	virsh shutdown almanode1 2>/dev/null || true
	virsh shutdown almanode2 2>/dev/null || true
	virsh shutdown almanode3 2>/dev/null || true
	@echo "[stop] AlmaLinux VMs shutting down"

stop-deb:
	virsh shutdown debnode1 2>/dev/null || true
	virsh shutdown debnode2 2>/dev/null || true

stop-ubu:
	virsh shutdown ubunode1 2>/dev/null || true
	virsh shutdown ubunode2 2>/dev/null || true
	@echo "[stop] Ubuntu VMs shutting down"

stop-fed:
	virsh shutdown fednode1 2>/dev/null || true
	virsh shutdown fednode2 2>/dev/null || true
	@echo "[stop] Fedora VMs shutting down"

stop: stop-alma stop-deb stop-ubu stop-fed

# ---- Start (boot existing VMs, then restart MattX) ----

start-alma:
	virsh start almanode1 2>/dev/null || true
	virsh start almanode2 2>/dev/null || true
	$(SCRIPTS)/start-mattx.sh alma 1
	$(SCRIPTS)/start-mattx.sh alma 2
	@echo "[start] AlmaLinux cluster ready"

# Only for clusters that provisioned almanode3 (make almacluster3) -- kept out
# of start-alma/start since starting a node that was never provisioned would
# hang in wait_for_ssh.
start-alma3: start-alma
	virsh start almanode3 2>/dev/null || true
	$(SCRIPTS)/start-mattx.sh alma 3
	@echo "[start] AlmaLinux 3-node cluster ready"

start-deb:
	virsh start debnode1 2>/dev/null || true
	virsh start debnode2 2>/dev/null || true
	$(SCRIPTS)/start-mattx.sh deb 1
	$(SCRIPTS)/start-mattx.sh deb 2
	@echo "[start] Debian cluster ready"

start-ubu:
	virsh start ubunode1 2>/dev/null || true
	virsh start ubunode2 2>/dev/null || true
	$(SCRIPTS)/setup-node.sh ubu 1
	$(SCRIPTS)/setup-node.sh ubu 2
	$(SCRIPTS)/start-mattx.sh ubu 1
	$(SCRIPTS)/start-mattx.sh ubu 2
	@echo "[start] Ubuntu cluster ready"

start: start-alma start-deb start-ubu

# ---- Status ----

status:
	@echo "=== VM power states ==="
	@for vm in almanode1 almanode2 almanode3 debnode1 debnode2 ubunode1 ubunode2; do \
	    state=$$(virsh domstate $$vm 2>/dev/null || echo "not defined"); \
	    printf "  %-12s %s\n" "$$vm" "$$state"; \
	done
	@echo ""
	@echo "=== Network ==="
	@virsh net-info mattx-test 2>/dev/null | grep -E "Name|Active" || echo "  mattx-test: not found"

# ---- Report table (per-run summary, keyed by kernel + mattx commit) ----

report-table:
	$(SCRIPTS)/report-table.py --format both --out reports/run-summary
	@echo "wrote reports/run-summary.md and reports/run-summary.html"

# ---- Destroy (deletes disks — full reprovision needed after this) ----

clean-alma:
	$(SCRIPTS)/destroy-vm.sh almanode1
	$(SCRIPTS)/destroy-vm.sh almanode2
	$(SCRIPTS)/destroy-vm.sh almanode3
	@rm -f $(STAMP)/alma-*

clean-deb:
	$(SCRIPTS)/destroy-vm.sh debnode1
	$(SCRIPTS)/destroy-vm.sh debnode2
	@rm -f $(STAMP)/deb-*

clean-ubu:
	$(SCRIPTS)/destroy-vm.sh ubunode1
	$(SCRIPTS)/destroy-vm.sh ubunode2
	@rm -f $(STAMP)/ubu-*

clean: clean-alma clean-deb clean-ubu
	@rm -rf $(STAMP)
	@echo "[clean] done"

