# Cleartext, Module 2: Layer 2, Frames, MACs, and Switches

### *And why the attacker sitting next to you on the coffee shop wifi already owns the network*

---

In Module 1 we walked the path of a packet from a laptop on a coffee shop wifi to a server somewhere on the internet. We treated Layer 2 as a thin wrapper that gets your packet across one hop. That was a useful simplification. It was also a lie of omission.

Layer 2 is where the most consequential attacks against an internal network actually live. Not because the attacks are clever, but because Layer 2 was designed in the 1980s for a world where everyone on the same wire trusted each other. That trust assumption never got fixed. It just got covered up with newer layers piled on top.

This module is about what happens when you stop covering it up.

---

## What Layer 2 actually does

The job of Layer 2 is simple: move a frame from one device to another device on the same physical (or logical) network segment. That's it. No routing across networks, no end-to-end reliability, no concept of an "internet." Just one hop.

To do that one hop, Layer 2 needs three things:

1. A way to address devices on the local segment. (MAC addresses.)
2. A frame format that a NIC can actually transmit. (Ethernet.)
3. A device that connects multiple endpoints and forwards frames between them. (A switch.)

Everything else at this layer, ARP, VLANs, STP, all of it, exists to make those three things work in the real world.

---

## MAC addresses, the burned-in identity

A MAC address is a 48-bit number, usually written as six hex bytes separated by colons:

```
aa:bb:cc:11:22:33
```

The first three bytes are the OUI (Organizationally Unique Identifier), assigned by the IEEE to a hardware vendor. The last three bytes are assigned by that vendor to the specific device. So `00:50:56:xx:xx:xx` is a VMware NIC, `b8:27:eb:xx:xx:xx` is a Raspberry Pi, and so on. There are public OUI lookup databases, and Wireshark will resolve the vendor for you automatically.

There are three kinds of MAC addresses worth knowing:

- **Unicast.** A normal address belonging to one device. The least significant bit of the first byte is `0`.
- **Multicast.** An address that a group of devices have agreed to listen on. The least significant bit of the first byte is `1`. Used heavily by routing protocols, IPv6 neighbor discovery, and streaming.
- **Broadcast.** The all-ones address, `ff:ff:ff:ff:ff:ff`. Every device on the segment receives a frame sent here. ARP requests use this.

MAC addresses are supposed to be globally unique and burned into the NIC at the factory. In practice, every modern operating system can change its MAC in one command. Remember that, it matters in about three sections from now.

---

## The Ethernet frame

When your IP packet drops down to Layer 2, it gets wrapped in an Ethernet frame. The header is small:

```
[ Destination MAC | Source MAC | EtherType | Payload | FCS ]
      6 bytes        6 bytes     2 bytes    46-1500    4 bytes
```

The EtherType field tells the receiver what's inside the frame. `0x0800` means IPv4. `0x86DD` means IPv6. `0x0806` means ARP. The receiver uses this to hand the payload to the right protocol stack.

The FCS at the end is a checksum. If the frame got corrupted in transit, the receiver drops it silently. There is no retransmission at Layer 2; that's a job for higher layers (or for the application to give up).

That's the whole frame. It's intentionally minimal. Ethernet was built to be cheap and fast, not safe.

---

## Switches and the CAM table

A switch is a device with many ports, each connected to one endpoint (a laptop, a printer, another switch). When a frame comes in on one port, the switch's job is to forward it out the right port and only the right port. To do that, the switch maintains a table that maps MAC addresses to ports. This table goes by several names: the CAM table, the MAC address table, the forwarding table. Same thing.

The switch builds this table by watching traffic. Every frame that arrives carries a source MAC, and the switch records "I saw MAC X on port Y." Over time, it learns where every device lives.

When a frame arrives and the destination MAC is in the table, the switch forwards the frame out only the matching port. This is called a *unicast forward*, and it's why a switched network is more private than a hub: traffic between two endpoints doesn't get copied to everyone else.

When a frame arrives and the destination MAC is **not** in the table, the switch has no choice. It floods the frame out every port except the one it arrived on, hoping the right device will respond and reveal its location. This is called *unknown unicast flooding*, and it is the seam that one of the attacks below pries open.

Broadcast and multicast frames are always flooded.

---

## ARP, the glue between Layer 3 and Layer 2

Your operating system thinks in IP addresses. Your NIC transmits Ethernet frames. Something has to translate "I want to send a packet to 192.168.1.1" into "put this frame on the wire with destination MAC `aa:bb:cc:11:22:33`." That something is ARP, the Address Resolution Protocol.

ARP works like this:

1. Your laptop wants to send a packet to 192.168.1.1 but doesn't know its MAC.
2. Your laptop broadcasts an ARP request: "Who has 192.168.1.1? Tell me at my MAC."
3. Every device on the segment receives the broadcast. The device that owns 192.168.1.1 sends a unicast ARP reply: "I have 192.168.1.1, my MAC is `aa:bb:cc:11:22:33`."
4. Your laptop caches that mapping in its ARP table for a few minutes and uses it to address the frame.

The fundamental problem with ARP is right there in step 4. There is no authentication. Anyone on the segment can send a reply, and the laptop will believe it. Worse, most operating systems will accept *unsolicited* ARP replies and update their cache. They never even asked.

This is the door. Almost every Layer 2 attack walks through it.

---

## Where attackers live at Layer 2

Now the fun part.

### ARP spoofing (or ARP poisoning)

The attacker sits on the same network as the victim. They send a stream of unsolicited ARP replies to the victim's laptop saying "I have 192.168.1.1, my MAC is *(the attacker's MAC)*." The victim's laptop dutifully updates its ARP cache. From that moment, every packet the victim sends to the gateway gets sent to the attacker instead.

The attacker forwards the traffic to the real gateway so the victim doesn't notice anything broken. They are now in the middle. They can passively read everything that isn't end-to-end encrypted. They can selectively drop packets. They can modify HTTP responses on the fly. If the victim is unlucky enough to be using a service without HTTPS, or one with broken certificate validation, the attacker reads the credentials in plaintext.

This attack works against an unmodified default-configured network in 2026. Every offensive security course on Earth covers it. Every defender should be able to detect it.

We will run it in the lab.

### MAC flooding

This one targets the switch itself rather than a victim laptop. The attacker generates frames with random source MAC addresses, thousands per second. Every new MAC the switch sees gets recorded in the CAM table. The CAM table has a finite size (a few thousand to a few hundred thousand entries depending on the model). Eventually it fills up.

When the CAM table is full, the switch can't learn any new mappings. Frames destined for MACs it doesn't know about get flooded out every port. The switch has effectively turned back into a hub. The attacker, sitting on any port, now sees traffic between every other pair of devices on the segment.

Modern enterprise switches have port-security features that limit the number of MACs allowed per port and shut the port down if the limit is exceeded. Default-configured consumer and small-business switches typically do not.

### VLAN hopping

VLANs (Virtual LANs) let one physical switch present itself as multiple logically-isolated networks. The guest wifi VLAN, the corporate VLAN, the IoT VLAN, the management VLAN, all carried on the same hardware but separated by a tag in the Ethernet header.

VLAN hopping is the family of attacks that escapes that separation. The two classic variants:

- **Switch spoofing.** Many switches default to negotiating trunk links automatically (DTP, Dynamic Trunking Protocol). An attacker can pretend to be a switch, negotiate a trunk, and receive traffic from every VLAN on the device.
- **Double tagging.** The attacker crafts a frame with two VLAN tags. The first switch strips the outer tag and forwards the frame; the second switch reads the inner tag as if it were legitimate, delivering the frame to a VLAN the attacker shouldn't have access to. This works when the attacker is on the native VLAN of a trunk.

Both attacks have been known and documented for two decades. Both still work against poorly configured switches.

### Rogue DHCP and DHCP starvation

Strictly, DHCP is a Layer 7 protocol that runs over UDP. But it lives at the Layer 2 boundary because it depends on broadcast and because it determines the gateway and DNS settings every device on the segment will trust. So we cover it here.

A rogue DHCP server is an attacker-run service that responds to DHCP requests faster than the legitimate server. The attacker hands out leases pointing victims at an attacker-controlled gateway and DNS resolver. That's man-in-the-middle without even needing ARP spoofing.

DHCP starvation is the inverse. The attacker requests every available lease from the legitimate DHCP server, exhausting the pool. New devices joining the network get no IP, opening the door for the rogue server to fill the gap.

Module 5 goes deeper on DHCP. For now, just know that the attack surface is real and starts at Layer 2.

### STP attacks

Spanning Tree Protocol prevents loops in switched networks by electing a "root bridge" and disabling redundant links. STP messages have no authentication. An attacker can send a forged STP message claiming to be the root bridge, causing the switch topology to rebalance around them, often funneling more traffic through their port in the process.

This attack is rare in the wild because it's noisy and most enterprise switches have BPDU Guard enabled, which shuts down any port that sends an STP message it shouldn't. But the protocol weakness is still there.

---

## Why Layer 2 keeps biting people

Most of these attacks were documented in the 1990s. They keep working because:

1. **The protocols can't be fixed without breaking compatibility.** ARP, STP, and DTP have no notion of authentication and adding it would mean replacing every NIC and switch in the world. So the industry layered defenses (port security, DAI, BPDU Guard, 802.1X) on top instead of fixing the protocols.

2. **The defenses are off by default.** Every modern enterprise switch has features that would stop these attacks cold. Most are disabled out of the box because enabling them aggressively breaks legitimate traffic if misconfigured. That means a network is only as secure as its most-overlooked switch port.

3. **Layer 2 is invisible to most security tools.** Endpoint EDR sees the operating system. Network detection sees IP and above. Almost nothing watches the ARP table or the CAM table. ARP spoofing on an internal network can run for weeks before anyone notices.

4. **The attacker needs to be local. That bar is lower than you think.** Open guest wifi, an unattended ethernet jack in a conference room, a compromised printer, a contractor's laptop. The "local network" boundary is much more porous than the "external attacker" boundary that most defenders worry about.

---

## What this looks like on the wire

If you fire up Wireshark and capture on a coffee shop wifi for sixty seconds, here is what you will see at Layer 2:

- A flood of ARP requests, mostly from devices trying to resolve the gateway.
- Periodic ARP announcements (gratuitous ARPs) from devices that just got an IP lease.
- 802.11 management frames if you're on wifi (those deserve their own module, see Module 8).
- Multicast DNS, SSDP, and other discovery chatter that most users don't realize their devices are screaming into the void.
- If anyone is doing anything malicious, ARP replies that don't match any request, or repeated ARP entries with conflicting MAC-to-IP mappings.

Wireshark has a built-in expert system that flags "duplicate IP address detected" when it sees an ARP poisoning pattern. That alert is the single easiest manual detection for ARP spoofing on a small network.

We use this in the lab.

---

## What we'll do in the lab

The Module 2 lab spins up a small switched topology in Containerlab: two endpoints, one switch, one attacker container on the same segment. You will:

1. Capture normal ARP traffic and identify the gateway, the endpoints, and their MACs.
2. Run an ARP spoofing attack from the attacker container against one of the endpoints.
3. Confirm in Wireshark that the victim's traffic is now flowing through the attacker.
4. Configure switch port-security on the topology and watch the attack fail.

Total time: about thirty minutes once your environment is built. The lab guide is in `lab/README.md`.

---

## Where this fits in the course

- **Module 3** picks up the IP packet that Layer 2 just delivered and follows it across networks.
- **Module 5** revisits DHCP in depth with the rogue server attack in a lab.
- **Module 7** covers VLAN design and segmentation at scale, including the defenses against the attacks we just walked through.
- **Module 11** covers what the defender's tooling actually sees during a Layer 2 attack and how to alert on it.

---

## What to do next

Run the lab. Capture the ARP poisoning traffic in Wireshark. Then try this on your own network: open Wireshark on your laptop and watch the ARP table for sixty seconds. Look at how chatty your "quiet" network actually is. That noise is the substrate every Layer 2 attack hides in.

The next module follows the IP packet upstream into the routing world. If Layer 2 is the local neighborhood, Layer 3 is the road network that connects every neighborhood on Earth. Different problems, different attackers, same pattern: a protocol designed for trust, deployed in a world that no longer has any.

---

*Cleartext is a course on networking and network security taught by Brandon Russell, an Air Force cyber instructor with an Ed.D. in Educational Leadership, an M.S. in Information Technology, and certifications including OSCP and CISSP.*
