# Cleartext, Module 3: Layer 3, IP, Routing, and ICMP

### *And how a packet finds its way across a network nobody actually owns*

---

In Module 2 we watched a frame get handed off from one device to another on a single segment of wire. That's a useful trick if everything you care about lives in the same room. It is not how the internet works.

The internet works because of Layer 3. Layer 3 is the layer that decides "this packet is destined for an address I don't have a direct connection to, but I know someone who's a little closer, so I'll forward it to them." Repeat that decision a few dozen times across a few dozen unrelated networks owned by a few dozen unrelated companies, and a packet from your laptop in a coffee shop in Ohio reaches a server in Singapore in 200 milliseconds.

Nobody owns the path. Nobody plans the path. The path emerges from a billion tiny decisions made independently by routers that have never met and will never coordinate. Understanding why this works, and where the trust assumptions baked into it break, is the entire point of this module.

---

## What Layer 3 actually does

The job of Layer 3 is to move a packet across networks, plural. Layer 2 gets you across one wire. Layer 3 gets you across the planet.

To do that, Layer 3 needs three things:

1. A way to address devices globally, not just locally. (IP addresses.)
2. A header format that carries enough information for any router on the path to forward the packet correctly. (The IP header.)
3. A mechanism by which routers learn where networks are and choose a next hop toward them. (Routing.)

There is also a fourth thing, which is a way for Layer 3 itself to talk back when something goes wrong. (ICMP.) That one matters for both troubleshooting and attack surface, so it gets its own section.

---

## IP addresses, the global identity

An IPv4 address is a 32-bit number, usually written as four decimal bytes separated by dots:

```
192.168.1.42
```

That gives roughly 4.3 billion possible addresses. We ran out of those somewhere around 2011, which is why IPv6 exists. IPv6 is a 128-bit address space, written as eight groups of four hex digits separated by colons:

```
2001:0db8:85a3:0000:0000:8a2e:0370:7334
```

For the rest of this article I'll mostly use IPv4 because that's what you'll see most often in a lab and on most of the internet's user-facing edge. The concepts translate cleanly to IPv6, with the obvious caveat that the address space is unimaginably larger and that some Layer 3 mechanics (notably ARP) get replaced by Neighbor Discovery.

There are three categories of IPv4 address worth knowing right away:

- **Public.** Routable on the internet. Assigned by regional internet registries to ISPs, who hand them down to customers.
- **Private.** Not routable on the internet. Defined by RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16`. These are the addresses your home and office networks use internally before NAT translates them at the edge.
- **Special.** Loopback (`127.0.0.0/8`), link-local (`169.254.0.0/16`), multicast (`224.0.0.0/4`), and a handful of others. Each behaves differently from a normal address and you'll see them in real captures.

NAT, the mechanism that translates private addresses to a public address at the network edge, is its own topic and lives in Module 5. Just know for now that the source IP your laptop puts on a packet is almost never the source IP the destination server actually sees.

---

## Subnets and CIDR, the slash notation

A subnet is a contiguous block of IP addresses that share the same prefix. CIDR notation expresses that prefix as a number after a slash: `192.168.1.0/24` means "all addresses where the first 24 bits are `192.168.1`," which gives 256 addresses (`192.168.1.0` through `192.168.1.255`).

A few CIDR sizes you'll see constantly:

| CIDR | Addresses | Usual role |
|------|-----------|------------|
| `/32` | 1 | A single host |
| `/30` | 4 | Point-to-point router link |
| `/24` | 256 | A typical home or small office subnet |
| `/16` | 65,536 | A medium enterprise or campus |
| `/8` | 16.7M | An entire RFC 1918 private range |
| `/0` | All of IPv4 | The default route, "everywhere I don't know about" |

Routing tables are built on CIDR prefixes. When a router receives a packet, it finds the *most specific* (longest-prefix) entry in its table that matches the destination IP and forwards accordingly. This is called *longest prefix match*, and it's the single most important rule in IP routing.

---

## The IP header

Strip an IP packet down to the parts that actually matter and the IPv4 header looks like this:

```
[ Version | IHL | TOS | Total Length |
  Identification | Flags | Fragment Offset |
  TTL | Protocol | Header Checksum |
  Source IP | Destination IP |
  (Options, rarely used) | Payload ]
```

The fields you'll touch most often:

- **Source IP and Destination IP.** Self-explanatory, and the two fields attackers care about lying about.
- **TTL (Time To Live).** A counter that every router decrements by one. When it hits zero, the packet is dropped and an ICMP "Time Exceeded" message is sent back. This is what stops packets from looping forever, and it's what traceroute exploits to map the path.
- **Protocol.** A number that says what's inside the IP packet. `6` means TCP, `17` means UDP, `1` means ICMP. This is the Layer 3 equivalent of EtherType.
- **Identification, Flags, Fragment Offset.** The fragmentation machinery. If a packet is too big for the next link's MTU, it gets split into fragments that the receiver reassembles using these fields. Fragmentation is mostly avoided in modern networks (Path MTU Discovery and TCP MSS handle it before the fact), but the machinery is still there, and attackers know how to use it.
- **Header Checksum.** Covers only the IP header, not the payload. If it's wrong, the packet is dropped.

Notice what is *not* in the header: any kind of authentication, integrity protection, or sender verification. Anyone can put any source IP they want on a packet. The network has no way to tell. That single design decision drives a huge fraction of Layer 3 attack surface.

---

## Routing, how packets find their way

Every device that handles IP packets, your laptop included, has a routing table. The table is a list of CIDR prefixes paired with a next hop and an outbound interface. When a packet needs to be sent, the device looks up the destination IP, finds the most specific matching prefix, and forwards the packet toward the listed next hop.

Your laptop's routing table on a typical home network looks something like this:

```
Destination       Gateway          Interface
192.168.1.0/24    on-link          wlan0
0.0.0.0/0         192.168.1.1      wlan0
```

The first line says "for any address in my local subnet, the destination is on the same wire, just ARP for it." The second line, the *default route*, says "for literally everything else, hand the packet to 192.168.1.1 and let it figure out where to go next."

That gateway router has its own routing table, with its own default route pointing at the ISP. The ISP's routers have routing tables with thousands of entries learned from other ISPs via BGP. And so on, up the chain. No single router knows the full path. Each router only knows the next hop. The packet is forwarded one decision at a time.

There are two broad categories of routing:

- **Static routing.** A human types entries into the routing table by hand. Cheap, simple, and exactly as up-to-date as the human who maintains it. Common in small networks and inside specific links.
- **Dynamic routing.** Routers exchange information about which networks they can reach and how, automatically. Inside a single organization (an "autonomous system"), this is usually OSPF or EIGRP. Between organizations, this is BGP, the protocol that holds the entire internet together with a startling amount of trust.

We will not cover the details of OSPF or BGP in this module. Module 7 takes them apart. For now, the thing to internalize is that the entire global routing system is built on routers telling each other "I can reach this network, route through me," and the receiving routers mostly just believing them.

---

## ICMP, the network's error channel

ICMP (Internet Control Message Protocol) is how Layer 3 talks about itself. It runs directly on top of IP (Protocol number 1). ICMP carries diagnostic messages: "your packet's TTL hit zero," "the destination network is unreachable," "fragmentation needed but not allowed."

Two ICMP message types you've used personally even if you don't realize it:

- **Echo Request and Echo Reply (ping).** The classic "is this thing on?" probe. Your laptop sends an Echo Request, the destination replies with an Echo Reply, and the round-trip time tells you the path is reachable and roughly how laggy it is.
- **Time Exceeded (traceroute).** Traceroute sends packets with a deliberately small TTL: first a packet with TTL=1, then TTL=2, then TTL=3, and so on. Each hop along the path decrements the TTL to zero on a different packet and sends back a "Time Exceeded" message. The source IPs of those messages reveal the path one router at a time.

ICMP is operationally indispensable. It is also the most commonly abused protocol on the internet, partly because it's small, partly because it's allowed through firewalls that block almost everything else, and partly because most operators don't inspect it.

---

## Where attackers live at Layer 3

Now the fun part.

### IP spoofing

The simplest Layer 3 attack: lie about your source IP. The IP header has a field for it, the field has no protection, and any packet you craft can carry any source address you want. There are limits in practice, ISPs are supposed to do *egress filtering* (BCP 38) that drops outbound packets with source IPs that don't belong to their network, but compliance is uneven and a meaningful slice of the internet still allows spoofed packets to leave.

Spoofing matters in three ways:

- **Reflection and amplification attacks.** Send a small UDP query to a public service (DNS, NTP, memcached) with a spoofed source IP set to the victim. The service sends a much larger response to the victim. Multiply by thousands of services and you have a denial-of-service attack the victim can't trace back to you. We'll see this again in Module 4.
- **Bypassing IP-based access control.** Some legacy systems trust packets purely because of their source IP. If you can spoof that IP and you don't need to receive a response, you can sometimes act as that system.
- **Hiding the attacker.** A spoofed source IP makes attribution harder, even if it doesn't enable a clever attack on its own.

### ICMP tunneling

ICMP is small, ubiquitous, and almost universally trusted by firewalls. That makes it an attractive covert channel. ICMP tunneling tools (icmptunnel, ptunnel, and the like) hide arbitrary data inside the payload of Echo Request and Echo Reply packets. The data isn't visible to most network monitoring, which is looking for bad TCP and bad UDP and not really watching ICMP at all.

You will not see ICMP tunneling in a normal capture. You will see it in a forensics investigation after an organization realizes a quiet "ping flood" between two endpoints has been their data exfiltration channel for six months.

### Fragmentation attacks

When fragmentation was relevant, it was a goldmine for evasion. The attack family includes:

- **Tiny fragments.** Split a TCP header across two fragments so the first fragment doesn't contain the destination port. Some firewalls and IDS systems made forwarding decisions on the first fragment alone and missed that the actual port wasn't visible until reassembly.
- **Overlapping fragments.** Send fragments whose offsets overlap, with different content in the overlap. The IDS reassembles one way, the destination reassembles a different way, and the attacker slips past detection.
- **Resource exhaustion.** Send incomplete fragment streams that the destination has to hold in memory waiting for completion. With enough streams, you exhaust the reassembly buffer.

Modern stacks have hardened against most of this. Path MTU Discovery makes fragmentation rare in practice. But the machinery is still in the protocol, and old or embedded systems still do fragment reassembly the old way.

### BGP hijacking

The hardest attack to pull off but the most damaging. An attacker convinces internet routers that they own a chunk of address space they don't actually own, by sending a forged BGP announcement. Traffic destined for the hijacked network gets routed through the attacker instead.

This has happened in the wild. Some incidents are accidental fat-finger misconfigurations that leak announcements and reroute large chunks of internet traffic for hours. Some are deliberate, used to intercept cryptocurrency transactions, to surveil a region's traffic, or to take a competitor's service offline.

Mitigations exist (RPKI, route filtering, BGPsec) and are being deployed slowly, but the global routing system is still fundamentally a trust network. Module 7 covers BGP and its defenses in depth.

### Source routing

IP has an option that lets the sender specify the path the packet should take, hop by hop, instead of letting routers decide. This was useful in the 1980s. Today it is almost exclusively an attack vector: an attacker uses source routing to bypass network controls by directing the packet through a path that wasn't supposed to be used. Most operating systems and routers ignore source-routed packets by default now, but the option is still in the IP header.

### Smurf and other historical DoS attacks

The Smurf attack, popular in the late 1990s, sent ICMP Echo Requests to a network's broadcast address with a spoofed source IP set to the victim. Every device on the broadcast network would reply, drowning the victim in ICMP. Modern routers don't forward directed broadcasts by default, which killed Smurf. But the underlying pattern (small request to many devices, large response to one victim) is the template for every reflection attack since.

---

## Why Layer 3 keeps biting people

The Layer 3 attack surface keeps producing new variants of old problems for the same reasons Layer 2 does:

1. **The protocols predate the threat model.** IP, ICMP, and BGP were designed when the internet was a small club of universities and research labs. Adding authentication later means coordinating an upgrade across a network with no central authority and no way to make anyone do anything.

2. **The defenses depend on every operator being a good citizen.** BCP 38 egress filtering would kill IP spoofing if every ISP did it. RPKI would kill BGP hijacking if every network signed and validated their announcements. Both technologies have existed for years. Adoption is partial because there's no business reason for any single operator to be the first one to do the right thing.

3. **ICMP gets a free pass.** Operators block it inconsistently because blocking ICMP breaks Path MTU Discovery, traceroute, and other diagnostics. The result is that ICMP is one of the most widely-allowed protocols on the internet, and very little inspection touches it.

4. **The path is invisible to the endpoints.** Your laptop doesn't know what path its packets take. The server doesn't know either. Only the routers in the middle know, and they don't tell anyone. A BGP hijack can reroute your traffic through a hostile country and you have no signal that it happened, except possibly latency.

---

## What this looks like on the wire

Open Wireshark, run `ping 8.8.8.8`, and look at the capture. You'll see:

- An ARP request and reply (the laptop resolving the gateway's MAC, Layer 2 in service of Layer 3).
- A series of ICMP Echo Requests with sequence numbers incrementing.
- ICMP Echo Replies coming back with matching sequence numbers.
- Each request/reply pair has a TTL field. The replies will have a TTL of around 110-120, which tells you Google's edge is roughly 8-10 hops away (most stacks set the initial TTL to 128 and it gets decremented at each hop).

Now run `traceroute 8.8.8.8` (or `tracert` on Windows) and capture again. You'll see:

- Outbound packets with TTLs of 1, 2, 3, and so on.
- Incoming ICMP "Time Exceeded" messages from each hop along the path, with the source IP revealing each router.
- Eventually, an ICMP Echo Reply (or a UDP "port unreachable," depending on the traceroute implementation) from the destination itself.

That second capture is the entire Layer 3 routing system rendered visible in about thirty packets. Spend ten minutes staring at it and the abstract concept of "the internet routes packets" becomes a concrete picture you can point to.

---

## What we'll do in the lab

The Module 3 lab spins up a multi-router topology in Containerlab: three routers in a triangle, two endpoints attached to different routers, and the routers running OSPF so they learn each other's networks dynamically. You will:

1. Inspect the routing table on each router and watch how it changes as routes are learned.
2. Capture an ICMP exchange between the two endpoints and identify every hop.
3. Take down one of the router-to-router links and watch OSPF reconverge around the failure.
4. Run a traceroute and correlate the output to the topology you built.
5. Send a spoofed-source-IP packet from one of the endpoints and see what happens (and where it gets dropped).

Total time: about forty-five minutes once your environment is built. The lab guide is in `lab/README.md`.

---

## Where this fits in the course

- **Module 4** picks up the TCP and UDP segments that ride inside these IP packets and goes deep on the transport layer.
- **Module 5** covers the boring but critical infrastructure (DNS, DHCP, NAT) that makes Layer 3 usable for real applications.
- **Module 7** comes back to routing at scale, including OSPF, BGP, segmentation, and the defenses against the routing attacks we walked through here.
- **Module 11** covers what flow data and routing telemetry look like to a defender, and how to alert on the Layer 3 attacks above.

---

## What to do next

Run the lab. Get comfortable reading a routing table. Then try this on your own machine: open a terminal and look at your laptop's routing table (`ip route` on Linux, `route print` on Windows, `netstat -rn` on macOS). Find the default route. Trace one of your packets to a real internet destination and identify your ISP's first hop, the regional aggregation point, and where your traffic enters the destination's network.

The next module dives into Layer 4: TCP, UDP, the three-way handshake, and the scanning and flooding attacks that live in the transport layer. After that, you'll have a working mental model of every layer that runs on a packet from your laptop to a server, and the rest of the course starts stacking real-world attack and defense scenarios on top of that foundation.

---

*Cleartext is a course on networking and network security taught by Brandon Russell, an Air Force cyber instructor with an Ed.D. in Educational Leadership, an M.S. in Information Technology, and certifications including OSCP and CISSP.*
