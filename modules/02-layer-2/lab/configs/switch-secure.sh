#!/bin/sh
# switch-secure.sh
# Two defenses applied as ebtables rules on the bridge:
#
#   1. MAC port-security: each port may only forward frames whose Ethernet
#      source MAC matches the device that's supposed to be on that port.
#      This stops MAC flooding and basic MAC-spoofing.
#
#   2. Dynamic ARP Inspection (DAI): each port may only forward ARP
#      packets whose ARP-sender IP matches the IP that belongs to the
#      device on that port. This is what actually stops arpspoof, because
#      the attack lies inside the ARP payload, not in the Ethernet header.
#
# Real enterprise switches do both with one or two CLI commands
# ("switchport port-security maximum 1", "ip arp inspection vlan ..."). We
# implement them by hand here so you can see what they're actually doing.

set -e

if [ ! -f /configs/macs.env ]; then
    echo "ERROR: /configs/macs.env not found. Run validate.sh defend instead of this script directly." >&2
    exit 1
fi

. /configs/macs.env

# Reset
ebtables -F FORWARD || true

# 1. MAC port-security
ebtables -A FORWARD -i eth1 -s ! "$GATEWAY_MAC"   -j DROP
ebtables -A FORWARD -i eth2 -s ! "$VICTIM_MAC"    -j DROP
ebtables -A FORWARD -i eth3 -s ! "$BYSTANDER_MAC" -j DROP
ebtables -A FORWARD -i eth4 -s ! "$ATTACKER_MAC"  -j DROP

# 2. Dynamic ARP Inspection
ebtables -A FORWARD -p ARP -i eth1 --arp-ip-src ! "$GATEWAY_IP"   -j DROP
ebtables -A FORWARD -p ARP -i eth2 --arp-ip-src ! "$VICTIM_IP"    -j DROP
ebtables -A FORWARD -p ARP -i eth3 --arp-ip-src ! "$BYSTANDER_IP" -j DROP
ebtables -A FORWARD -p ARP -i eth4 --arp-ip-src ! "$ATTACKER_IP"  -j DROP

echo "switch: port-security and DAI rules applied"
ebtables -L FORWARD --Lc
