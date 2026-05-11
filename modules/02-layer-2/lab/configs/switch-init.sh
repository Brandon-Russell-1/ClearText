#!/bin/sh
# switch-init.sh
# Turn the "switch" container into an actual L2 switch by creating a Linux
# bridge and adding all the data interfaces (eth1-eth4) to it. eth0 stays
# off the bridge because that's the management interface Containerlab uses.

set -e

ip link add br0 type bridge
ip link set br0 up

for iface in eth1 eth2 eth3 eth4; do
    ip link set "$iface" master br0
    ip link set "$iface" up
done

# IPv6 chatter clutters the capture for Layer 2 demos. Quiet it.
sysctl -w net.ipv6.conf.br0.disable_ipv6=1 >/dev/null 2>&1 || true

echo "switch: br0 up with eth1, eth2, eth3, eth4 as ports"
