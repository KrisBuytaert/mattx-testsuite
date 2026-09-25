#!/bin/bash
# Shared SSH/rsync helpers. Source this, then call init_cluster <alma|deb>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/.."
KEYS_DIR="$TEST_DIR/keys"
SSH_KEY="$KEYS_DIR/mattx_test"
SSH_USER="mattx"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR"

node_ip() {
    case "$1" in
        almanode1) echo "192.168.100.11" ;;
        almanode2) echo "192.168.100.12" ;;
        almanode3) echo "192.168.100.13" ;;
        debnode1)  echo "192.168.100.21" ;;
        debnode2)  echo "192.168.100.22" ;;
        ubunode1)  echo "192.168.100.31" ;;
        ubunode2)  echo "192.168.100.32" ;;
        *) echo "ERROR: unknown node '$1'" >&2; exit 1 ;;
    esac
}

run_on() {
    local node="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_USER@$(node_ip "$node")" "$@"
}


rsync_to() {
    local src="$1" node="$2" dst="$3"
    # shellcheck disable=SC2086
    rsync -az --delete -e "ssh $SSH_OPTS" "$src" "$SSH_USER@$(node_ip "$node"):$dst"
}

rsync_from() {
    local node="$1" src="$2" dst="$3"
    # shellcheck disable=SC2086
    rsync -az -e "ssh $SSH_OPTS" "$SSH_USER@$(node_ip "$node"):$src" "$dst"
}

wait_for_ssh() {
    local node="$1"
    local ip
    ip="$(node_ip "$node")"
    echo "[wait] waiting for SSH on $node ($ip) ..."
    local i=0
    # shellcheck disable=SC2086
    until ssh $SSH_OPTS "$SSH_USER@$ip" true 2>/dev/null; do
        sleep 5
        i=$((i+1))
        [ "$i" -lt 180 ] || { echo "[error] SSH timeout on $node after 15 min"; exit 1; }
    done
    echo "[wait] $node ready"
}

# Wait until a node stops accepting SSH connections (i.e. has actually gone down).
# Use this immediately after issuing a reboot, before calling wait_for_ssh,
# to avoid a race where the node is still up when we start polling.
wait_for_ssh_down() {
    local node="$1"
    local ip
    ip="$(node_ip "$node")"
    echo "[wait] waiting for $node ($ip) to go offline..."
    local i=0
    # shellcheck disable=SC2086
    while ssh $SSH_OPTS "$SSH_USER@$ip" true 2>/dev/null; do
        sleep 3
        i=$((i+1))
        [ "$i" -lt 40 ] || break  # 2 min max; if it never went down, proceed anyway
    done
    echo "[wait] $node is offline"
}

# Migration entry point used by every EESSI/GROMACS/chain test. Two
# interchangeable tools exist for the exact same underlying kernel
# operation, selected via MATTX_TOOL (default: raw, preserving this suite's
# original behavior):
#   - raw:         echo 'migrate <pid> <target>' | sudo tee /proc/mattx/admin
#                  (what every script here used exclusively until this was
#                  added -- no safety checks of its own, just a straight
#                  write into the kernel's admin interface)
#   - mattx-admin: the upstream CLI (bin/mattx-admin in the main mattx
#                  repo, already deployed to every test node at
#                  /usr/local/bin/mattx-admin by deploy-mattx.sh). It adds
#                  checks raw does not have -- notably, it refuses a direct
#                  remote-to-remote hop ("already migrated to node X,
#                  please migrate it 'home' first") instead of silently
#                  attempting it. See the chain-migration "Known bug" note
#                  in README.md for why that refusal matters: raw lets the
#                  unsupported hop through, and it corrupts state instead
#                  of failing cleanly.
# $target is a numeric node id, "home", or "best" -- both tools accept the
# same vocabulary. Returns mattx-admin's exit code (0 on success, non-zero
# if it refused); raw's write always "succeeds" from the shell's point of
# view even when the underlying migration can't actually work.
mattx_migrate() {
    local node="$1" pid="$2" target="$3"
    case "${MATTX_TOOL:-raw}" in
        raw)
            run_on "$node" "echo 'migrate ${pid} ${target}' | sudo tee /proc/mattx/admin > /dev/null"
            ;;
        mattx-admin)
            # Full path: sudo's secure_path doesn't include /usr/local/bin.
            run_on "$node" "sudo /usr/local/bin/mattx-admin migrate ${pid} ${target}"
            ;;
        *)
            echo "ERROR: unknown MATTX_TOOL '${MATTX_TOOL}' (want 'raw' or 'mattx-admin')" >&2
            exit 1
            ;;
    esac
}

# Human-readable label for whichever tool mattx_migrate() is currently
# using, for status lines ("command: ... (via $MATTX_TOOL_LABEL)").
mattx_tool_label() {
    case "${MATTX_TOOL:-raw}" in
        raw)         echo "raw /proc/mattx/admin" ;;
        mattx-admin) echo "mattx-admin CLI" ;;
        *)           echo "${MATTX_TOOL:-raw}" ;;
    esac
}

init_cluster() {
    local distro="$1"
    case "$distro" in
        alma|deb|ubu) ;;
        *) echo "ERROR: unknown distro '$distro'" >&2; exit 1 ;;
    esac
    [ -f "$SSH_KEY" ] || {
        echo "ERROR: SSH key $SSH_KEY not found — run: make keys" >&2
        exit 1
    }
}

check_prereqs() {
    local ok=1
    for cmd in virsh virt-install qemu-img rsync ssh curl; do
        command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found" >&2; ok=0; }
    done
    { command -v cloud-localds || command -v genisoimage || command -v mkisofs; } \
        >/dev/null 2>&1 || {
        echo "ERROR: need cloud-localds, genisoimage, or mkisofs for seed ISOs" >&2
        ok=0
    }
    [ "$ok" -eq 1 ]
}

# Give every test script a full, timestamped transcript on disk (reports/,
# gitignored) in addition to whatever the caller sees on stdout — so a
# failing run can be handed back by report filename instead of pasted
# output. Call as the first thing after TEST_DIR/DISTRO are known:
#     auto_report_wrap "run-tests" "$@"
# Re-execs the script once through `tee`, guarded by REPORT_ACTIVE to avoid
# recursing forever; the child (real test run) inherits the guard and runs
# normally, its combined stdout+stderr streamed live and captured to file.
# Numeric per-node "cursor" into the kernel ring buffer (seconds of uptime
# at capture time), for scoping a later oops/BUG scan to only what's new
# since this test run started. Without it, a pre-existing oops from an
# earlier session (or an earlier test in the same run) makes every
# subsequent check report a false "kernel oops" forever; conversely, ring
# buffer rotation under load could scroll a genuinely new oops out of a
# fixed `tail -N` before it's ever seen.
dmesg_cursor() {
    local node="$1"
    run_on "$node" "cat /proc/uptime | awk '{print \$1}'" 2>/dev/null || echo 0
}

# True (exit 0) if no Oops/BUG line in dmesg on $node has a timestamp newer
# than $cursor (a value previously captured via dmesg_cursor on that node).
#
# The timestamp extraction below MUST use a regex match on the whole line,
# not `$1` after default awk field-splitting. dmesg right-pads the number
# inside the brackets for column alignment -- e.g. "[  921.895536]" -- and
# whitespace is itself a field separator, so `$1` silently ends up being
# just "[" for any uptime under ~10000s (i.e. under ~2.7 hours, which is
# every single test run against a freshly booted/rebooted node). That
# collapses `ts` to 0 after stripping brackets, and `0 > cursor` is false
# for any positive cursor -- so this check always reported "no new oops"
# regardless of whether one actually occurred. Confirmed live: a real,
# freshly-logged line ("Network send failed! (ret: -32)") at uptime 921s
# was silently dropped by the old `$1`-based version. Match the bracketed
# span directly instead so column padding can't break the comparison.
no_new_oops() {
    local node="$1" cursor="$2"
    ! run_on "$node" "sudo dmesg" 2>/dev/null | awk -v c="$cursor" '
        match($0, /^\[[ 0-9.]+\]/) {
            ts = substr($0, RSTART + 1, RLENGTH - 2)
            gsub(/ /, "", ts)
            if ((ts + 0) > (c + 0)) print
        }
    ' | grep -q "Oops\|BUG: unable to handle\|kernel BUG"
}

# Printed automatically when a test fails, ahead of that test's own
# repro_testN() block -- gives a reviewer the env vars needed to replay the
# repro_testN() commands by hand.
repro_setup() {
    cat <<'SETUP'

  To reproduce manually, set these in your shell first:
    export MATTX_KEY="<path-to-test>/keys/mattx_test"
    # AlmaLinux: N1=192.168.100.11  N2=192.168.100.12
    # Debian:    N1=192.168.100.21  N2=192.168.100.22
    export N1=192.168.100.11
    export N2=192.168.100.12
    export SSH="ssh -i $MATTX_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mattx@"
    export N2_ID=$($SSH${N2} 'cat /proc/mattx/nodes' | awk '/\(Local\)/{print $1}')
SETUP
}

# Print ps evidence for a process pattern on one node. We search by pattern
# rather than by the home-node PID: mattx-stub is a distinct process spawned
# locally on the remote node via call_usermodehelper, so it gets its own
# kernel-assigned PID there — the original home PID has no reason to exist
# as a process on the remote node at all, so `ps -p <home-pid>` on the
# Surrogate's node reliably (and misleadingly) finds nothing.
# The exact remote command is echoed first so the evidence is self-proving:
# a reviewer can see which host it ran on and what was asked, not just the
# result.
show_location() {
    local pattern="$1" node="$2"
    local ip; ip="$(node_ip "$node")"
    local cmd="ps -eo pid,ppid,user,stat,%cpu,etime,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep"
    echo "  mattx@${node} (${ip})\$ $cmd"
    local out
    out="$(run_on "$node" "$cmd" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        echo "$out" | sed 's/^/      /'
    else
        echo "      (no process matching '$pattern' on $node)"
    fi
}

# Announce and execute a migration.
# $6 (actual_from) is optional and only needed for the "home" recall path,
# where the admin command must be issued on the home node ($from) but the
# job is actually currently running somewhere else -- without it, the log
# misleadingly shows "from: home_node to: home_node" for a migration that's
# really coming from wherever the job currently lives. Defaults to $from
# (the ordinary forward-migration case, where they're the same node).
do_migrate() {
    local name="$1" pid="$2" from="$3" to="$4" to_id="$5" actual_from="${6:-$3}"
    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo "  Starting migration of $name [PID $pid]"
    echo "    from : $actual_from ($(node_ip "$actual_from"))"
    echo "    to   : $to   ($(node_ip "$to"))  [node ID $to_id]"
    if [ "$from" != "$actual_from" ]; then
        echo "    (admin command issued on $from, the home node -- not on $actual_from, where the job actually is)"
    fi
    echo "    tool : $(mattx_tool_label)   (run on $from)"
    echo "  ─────────────────────────────────────────────────────"
    mattx_migrate "$from" "$pid" "$to_id"
}

# Wraps no_new_oops() with a fail() call on the caller's own PASS/FAIL
# counters -- the calling script must define pass()/fail() itself (every
# script that uses this does). Returns the same boolean as no_new_oops()
# so `check_no_oops ... && pass "..."` still works.
check_no_oops() {
    local node="$1" cursor="$2"
    if ! no_new_oops "$node" "$cursor"; then
        fail "kernel oops on $node"
        return 1
    fi
    return 0
}

# STAT field of the first process matching pattern on this node, or empty
# if no matching process exists at all. Distinguishes "gone" from "present
# but frozen" -- ps aux | grep can't, which silently produced false-positive
# PASSes before this check existed (see mattx#8 for a case that hid behind
# exactly this gap).
process_stat() {
    local pattern="$1" node="$2"
    run_on "$node" "ps -eo stat,cmd --no-headers | grep -iE -- '$pattern' | grep -v grep | awk '{print \$1}' | head -1" 2>/dev/null
}

# Is a process matching pattern actually EXECUTING on this node (STAT other
# than T=stopped or Z=zombie), as opposed to merely PRESENT?
is_actually_running() {
    local pattern="$1" node="$2"
    local stat; stat="$(process_stat "$pattern" "$node")"
    [ -n "$stat" ] && [[ "$stat" != T* && "$stat" != Z* ]]
}

# Prints the exact mattx git commit and each node's running kernel at the
# top of every report, so a report file is self-contained evidence of what
# it was actually run against -- without this, a report from a session
# investigating a version-dependent bug (see mattx#16/#17) can't be told
# apart from one that isn't, after the fact.
# NODE1/NODE2 (and DISTRO) are already in scope from the calling script by
# the time auto_report_wrap() runs -- see its case statement.
print_version_banner() {
    echo "=============================="
    echo "mattx commit: $(run_on "$NODE1" "cd ~/mattx && git rev-parse HEAD 2>/dev/null" || echo "unknown")"
    echo "$NODE1 kernel: $(run_on "$NODE1" "uname -r" 2>/dev/null || echo "unknown")"
    if [ -n "${NODE2:-}" ]; then
        echo "$NODE2 kernel: $(run_on "$NODE2" "uname -r" 2>/dev/null || echo "unknown")"
    fi
    if [ -n "${NODE3:-}" ]; then
        echo "$NODE3 kernel: $(run_on "$NODE3" "uname -r" 2>/dev/null || echo "unknown")"
    fi
    echo "=============================="
}

auto_report_wrap() {
    local label="$1"; shift
    if [ -n "${REPORT_ACTIVE:-}" ]; then
        print_version_banner
        return 0
    fi

    local reports_dir="$TEST_DIR/reports"
    mkdir -p "$reports_dir"
    local report_file="$reports_dir/${label}-${DISTRO}-$(date +%Y%m%d-%H%M%S).txt"

    echo "[report] full transcript: $report_file"
    export REPORT_ACTIVE=1
    local rc=0
    "$0" "$@" 2>&1 | tee "$report_file" || rc=$?
    echo ""
    echo "Full report: $report_file"
    exit "$rc"
}
