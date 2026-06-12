SCRIPTS  := scripts
STAMP    := .stamp
KEYS_DIR := keys

# Fixed IPs for reference
# almanode1: 192.168.100.11   almanode2: 192.168.100.12
# debnode1:  192.168.100.21   debnode2:  192.168.100.22

.PHONY: all alma debian almacluster debcluster allclusters \
        upgrade-alma upgrade-deb \
        test-alma test-deb \
        start-alma start-deb start \
        stop-alma stop-deb stop \
        status \
        clean-alma clean-deb clean \
        keys check

all:
	@echo "Provisioning:"
	@echo "  make alma          provision single AlmaLinux 10 node (almanode1)"
	@echo "  make debian        provision single Debian 13 node   (debnode1)"
	@echo "  make almacluster   2-node AlmaLinux cluster: provision + build + start MattX"
	@echo "  make debcluster    2-node Debian cluster:    provision + build + start MattX"
	@echo "  make allclusters   both clusters"
	@echo ""
	@echo "Daily use (VMs stay on disk, no reprovisioning):"
	@echo "  make stop          graceful shutdown of all VMs"
	@echo "  make stop-alma     graceful shutdown of AlmaLinux VMs"
	@echo "  make stop-deb      graceful shutdown of Debian VMs"
	@echo "  make start         start all VMs + restart MattX"
	@echo "  make start-alma    start AlmaLinux VMs + restart MattX"
	@echo "  make start-deb     start Debian VMs + restart MattX"
	@echo "  make status        show VM power states"
	@echo ""
	@echo "Upgrade (rebuild + reload on running cluster):"
	@echo "  make upgrade-alma  rebuild MattX and reload modules on AlmaLinux cluster"
	@echo "  make upgrade-deb   rebuild MattX and reload modules on Debian cluster"
	@echo ""
	@echo "Testing:"
	@echo "  make test-alma     run migration tests on AlmaLinux cluster"
	@echo "  make test-deb      run migration tests on Debian cluster"
	@echo ""
	@echo "Destruction (deletes disks — requires full reprovision):"
	@echo "  make clean-alma    destroy AlmaLinux VMs and disks"
	@echo "  make clean-deb     destroy Debian VMs and disks"
	@echo "  make clean         destroy everything"
	@echo ""
	@echo "Provisioning is idempotent: re-running skips completed steps."

check:
	@command -v virsh        >/dev/null || { echo "ERROR: virsh not found (install libvirt)"; exit 1; }
	@command -v virt-install >/dev/null || { echo "ERROR: virt-install not found"; exit 1; }
	@command -v qemu-img     >/dev/null || { echo "ERROR: qemu-img not found"; exit 1; }
	@command -v rsync        >/dev/null || { echo "ERROR: rsync not found"; exit 1; }
	@command -v curl         >/dev/null || { echo "ERROR: curl not found"; exit 1; }
	@{ command -v cloud-localds || command -v genisoimage || command -v mkisofs; } \
		>/dev/null 2>&1 || \
		{ echo "ERROR: need cloud-localds, genisoimage, or mkisofs"; exit 1; }

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
		52:54:00:0b:00:21=192.168.100.21 \
		52:54:00:0b:00:22=192.168.100.22
	@touch $@

# ---- VM provisioning ----

$(STAMP)/alma-vms: $(STAMP)/network | keys
	$(SCRIPTS)/create-vm.sh alma 1
	$(SCRIPTS)/create-vm.sh alma 2
	$(SCRIPTS)/setup-node.sh alma 1
	$(SCRIPTS)/setup-node.sh alma 2
	@touch $@

$(STAMP)/deb-vms: $(STAMP)/network | keys
	$(SCRIPTS)/create-vm.sh deb 1
	$(SCRIPTS)/create-vm.sh deb 2
	$(SCRIPTS)/setup-node.sh deb 1
	$(SCRIPTS)/setup-node.sh deb 2
	@touch $@

# ---- Build & deploy MattX ----

$(STAMP)/alma-built: $(STAMP)/alma-vms
	$(SCRIPTS)/build-mattx.sh alma
	@touch $@

$(STAMP)/deb-built: $(STAMP)/deb-vms
	$(SCRIPTS)/build-mattx.sh deb
	@touch $@

$(STAMP)/alma-deployed: $(STAMP)/alma-built
	$(SCRIPTS)/deploy-mattx.sh alma
	@touch $@

$(STAMP)/deb-deployed: $(STAMP)/deb-built
	$(SCRIPTS)/deploy-mattx.sh deb
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

almacluster: $(STAMP)/alma-deployed
	$(SCRIPTS)/start-mattx.sh alma 1
	$(SCRIPTS)/start-mattx.sh alma 2
	@echo ""
	@echo "AlmaLinux cluster ready:"
	@echo "  almanode1: 192.168.100.11"
	@echo "  almanode2: 192.168.100.12"
	@echo "  ssh mattx@192.168.100.11 -i $(KEYS_DIR)/mattx_test"

debcluster: $(STAMP)/deb-deployed
	$(SCRIPTS)/start-mattx.sh deb 1
	$(SCRIPTS)/start-mattx.sh deb 2
	@echo ""
	@echo "Debian cluster ready:"
	@echo "  debnode1: 192.168.100.21"
	@echo "  debnode2: 192.168.100.22"
	@echo "  ssh mattx@192.168.100.21 -i $(KEYS_DIR)/mattx_test"

allclusters: almacluster debcluster

# ---- Upgrade (rebuild + reload on running cluster, no reprovisioning) ----

upgrade-alma:
	$(SCRIPTS)/build-mattx.sh alma
	$(SCRIPTS)/deploy-mattx.sh alma
	$(SCRIPTS)/start-mattx.sh alma 1
	$(SCRIPTS)/start-mattx.sh alma 2

upgrade-deb:
	$(SCRIPTS)/build-mattx.sh deb
	$(SCRIPTS)/deploy-mattx.sh deb
	$(SCRIPTS)/start-mattx.sh deb 1
	$(SCRIPTS)/start-mattx.sh deb 2

# ---- Test targets ----

test-alma:
	$(SCRIPTS)/run-tests.sh alma

test-deb:
	$(SCRIPTS)/run-tests.sh deb

# ---- Stop (graceful shutdown, VMs and disks preserved) ----

stop-alma:
	virsh shutdown almanode1 2>/dev/null || true
	virsh shutdown almanode2 2>/dev/null || true
	@echo "[stop] AlmaLinux VMs shutting down"

stop-deb:
	virsh shutdown debnode1 2>/dev/null || true
	virsh shutdown debnode2 2>/dev/null || true
	@echo "[stop] Debian VMs shutting down"

stop: stop-alma stop-deb

# ---- Start (boot existing VMs, then restart MattX) ----

start-alma:
	virsh start almanode1 2>/dev/null || true
	virsh start almanode2 2>/dev/null || true
	$(SCRIPTS)/setup-node.sh alma 1
	$(SCRIPTS)/setup-node.sh alma 2
	$(SCRIPTS)/start-mattx.sh alma 1
	$(SCRIPTS)/start-mattx.sh alma 2
	@echo "[start] AlmaLinux cluster ready"

start-deb:
	virsh start debnode1 2>/dev/null || true
	virsh start debnode2 2>/dev/null || true
	$(SCRIPTS)/setup-node.sh deb 1
	$(SCRIPTS)/setup-node.sh deb 2
	$(SCRIPTS)/start-mattx.sh deb 1
	$(SCRIPTS)/start-mattx.sh deb 2
	@echo "[start] Debian cluster ready"

start: start-alma start-deb

# ---- Status ----

status:
	@echo "=== VM power states ==="
	@for vm in almanode1 almanode2 debnode1 debnode2; do \
	    state=$$(virsh domstate $$vm 2>/dev/null || echo "not defined"); \
	    printf "  %-12s %s\n" "$$vm" "$$state"; \
	done
	@echo ""
	@echo "=== Network ==="
	@virsh net-info mattx-test 2>/dev/null | grep -E "Name|Active" || echo "  mattx-test: not found"

# ---- Destroy (deletes disks — full reprovision needed after this) ----

clean-alma:
	$(SCRIPTS)/destroy-vm.sh almanode1
	$(SCRIPTS)/destroy-vm.sh almanode2
	@rm -f $(STAMP)/alma-*

clean-deb:
	$(SCRIPTS)/destroy-vm.sh debnode1
	$(SCRIPTS)/destroy-vm.sh debnode2
	@rm -f $(STAMP)/deb-*

clean: clean-alma clean-deb
	@rm -rf $(STAMP)
	@echo "[clean] done"
