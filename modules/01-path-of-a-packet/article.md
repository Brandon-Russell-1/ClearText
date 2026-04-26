# Cleartext, Module 1: The Path of a Packet

### *And why every cyberattack you'll ever read about lives somewhere on it*

---

You type `curl https://example.com` and hit enter. 200 milliseconds later, the server's response is on your screen.

In that 200 milliseconds, a lot happened. Your operating system had to figure out who `example.com` actually was. Your laptop had to find a way out of the local network. A handful of routers somewhere on the public internet had to agree on how to forward your packet. The server had to reassemble what arrived, decide it was a real request, hand it up to a web server process, generate a response, and send the whole thing back the way it came.

Every cyberattack you have ever read about lives somewhere in that 200 milliseconds.

That's the claim this course is built on. If you understand how a packet travels, you have a map. Once you have the map, every attack technique, every defensive control, and every detection signal slots into a place you already understand. Without the map, security training is just a pile of acronyms.

This article is the map.

---

## The problem with how networking gets taught

Most networking courses open with the OSI model on slide three. Seven layers, top to bottom, neatly stacked. You're asked to memorize them. A week later you can recite the layers but you have no idea what they're for, and you definitely don't know why anyone would care.

There's a better way to teach this.

Every layer in the network stack has two things worth knowing: a job and an attack surface. The job is what the protocol designers built it to do. The attack surface is what shows up when you start asking *what happens when someone lies at this layer?* You can't really teach one without the other, and you certainly can't operate as a security professional if you only know the first half.

At each layer below, I describe what the layer does, what's in its headers, and what kind of attacks live there. The deep dives in later modules go to the bottom of each layer in turn. This article is the orientation.

---

## The scenario we'll follow

You're at a coffee shop. You're on the open wifi. You type:

```
curl https://example.com
```

Before any packet leaves your laptop, several things have to be true:

1. Your laptop knows its own IP address. (DHCP handled that when you joined the wifi.)
2. Your laptop knows the IP address of the gateway router. (DHCP again.)
3. Your laptop knows the IP address of `example.com`. (DNS, just now.)
4. Your laptop knows the MAC address of the gateway router. (ARP, just now.)

That's already four protocols, and we haven't sent the actual HTTP request yet. Each one is its own attack surface. Module 5 covers DNS and DHCP. Module 2 covers ARP. We'll mention them in passing here and come back.

Once those four facts are in hand, your operating system can build the actual packet that carries your request. It builds the packet from the inside out, wrapping each piece in another envelope. This is called *encapsulation*, and it's the core mental model in networking.

---

## Encapsulation, layer by layer

### Layer 7: Application. Your request, in the words of the protocol

At the top of the stack, your `curl` command produces an HTTP request. Stripped to its essence, it looks something like this:

```
GET / HTTP/1.1
Host: example.com
User-Agent: curl/8.4.0
Accept: */*
```

That's it. A few lines of plain text. HTTP is just a text-based protocol that asks for a resource by name. Your browser, your phone, every IoT device in your house, they all speak some flavor of this kind of application-layer protocol.

**Where attackers live here:** Almost every web vulnerability you've ever heard of. SQL injection, cross-site scripting, request smuggling, broken authentication. Applications are where developers make assumptions about input, state, and trust; assumptions are what attackers exploit. We'll touch on application-layer attacks throughout the course but they're not the main focus; other courses cover web app security in depth.

### Layer 4: Transport. Reliability and ports

Your HTTP request is too important to just throw at the network and hope for the best. So your operating system hands it to TCP, which wraps it in a TCP header.

The TCP header is small but it does a lot of work. It contains:
- A source port (something random, like 54321) and a destination port (443 for HTTPS, or 80 for plain HTTP)
- A sequence number, so the receiver can put pieces back in order
- Flags like SYN, ACK, FIN, RST that drive TCP's state machine
- A checksum

TCP's job is reliable, ordered delivery. Before any data flows, TCP performs the famous three-way handshake (SYN, SYN-ACK, ACK) to establish a connection. After that it tracks every byte, retransmits anything lost, and reorders anything that arrives out of sequence.

UDP is the simpler alternative. No handshake, no reliability, no ordering. UDP's value is its simplicity: it's the right choice for DNS, video calls, and anything where retransmitting a stale packet is worse than dropping it.

**Where attackers live here:** Port scanning is reconnaissance at this layer. SYN floods exhaust a server's connection table by starting handshakes that never complete. RST injection lets an attacker tear down a TCP connection by forging a single packet. UDP amplification attacks abuse the connectionless nature of UDP to turn small queries into massive responses pointed at a victim. Module 4 is the deep dive.

### Layer 3: Network. Addresses and routing

The TCP segment now gets wrapped in an IP header. IP is the layer that gets your packet across networks. The header contains:
- The source IP (your laptop's address on the coffee shop wifi)
- The destination IP (whatever DNS resolved `example.com` to)
- A TTL, so packets that get lost don't loop forever
- A protocol number that says "the thing inside me is TCP"

This is where routing happens. Every router on the path looks at the destination IP, consults a routing table, and forwards the packet toward the next router. No router on the public internet knows the full path; each one only knows the next hop. That's not a flaw, it's the design that lets the internet scale.

**Where attackers live here:** IP spoofing, lying about your source address. ICMP tunneling, smuggling data inside ping packets, which a lot of firewalls let through without inspection. Fragmentation attacks, splitting packets in ways that confuse intrusion detection systems. BGP hijacking, where an attacker convinces internet routers that they own a chunk of address space they don't actually own. Module 3 is the deep dive.

### Layer 2: Data Link. The local network

The IP packet now needs to actually move across a piece of wire (or wifi). For that, it gets wrapped one more time, in an Ethernet frame. The frame header contains:
- A source MAC address (your laptop's network card, burned in at the factory)
- A destination MAC address (the gateway router, learned via ARP)
- An EtherType that says "the thing inside me is IP"

MAC addresses are local. They only matter on the current network segment. As your packet hops from router to router across the internet, the IP addresses stay the same but the MAC addresses change at every hop. This is the part of networking that confuses people the most when they first learn it, and the part that opens the door to the Layer 2 attacks that follow.

**Where attackers live here:** This is where it gets fun. ARP poisoning lets an attacker on the same network as you convince your laptop that the attacker's MAC address is the gateway. Once that's true, all your traffic flows through them before reaching the real router. MAC flooding overflows a switch's address table and forces it to broadcast every frame to every port, turning a switched network back into a hub for the attacker's benefit. VLAN hopping escapes a segmentation boundary that the network was relying on for security. Module 2 is the deep dive.

### Layer 1: Physical. Bits on the wire

Finally, the frame becomes a sequence of electrical pulses on copper, light pulses on fiber, or radio waves in the air. Most security training skips this layer. Attackers don't.

**Where attackers live here:** Cable taps. Rogue access points. Wireless deauth attacks. Anything that involves physical access to the medium. Module 8 covers wireless attacks specifically. The threat model at Layer 1 is fundamentally about *who has physical or radio proximity to the network*, and it's why the coffee shop scenario is a real threat model, not a cliche.

---

## The packet on the wire

Stack all of those headers together and what actually goes on the wire looks like this, conceptually:

```
[ Ethernet header [ IP header [ TCP header [ HTTP request ] ] ] ]
```

Each layer is wrapped by the layer below it. Each layer is *opaque* to the layer below: the IP layer doesn't care what's inside the TCP segment, and the Ethernet layer doesn't care what's inside the IP packet. They just carry the payload they were handed.

On the other end, the server reverses the process. The NIC receives the bits. The driver hands the frame up to the IP stack, which strips the Ethernet header. The IP stack strips the IP header and hands the segment to TCP. TCP reassembles, strips its header, and hands the bytes to the web server process listening on port 443. The web server reads the HTTP request and generates a response. Then the whole thing happens in reverse, traveling back to your laptop.

That's the 200 milliseconds.

---

## OSI vs TCP/IP: why we still teach both

The OSI model has seven layers. The TCP/IP model has four (or five, depending on how you count). The OSI model is what gets drawn on whiteboards. TCP/IP is what actually got built and ships in every operating system.

You'll see both in this course because both are useful for different things:

- **OSI** is better for *talking about networks*. When someone says "Layer 7 attack" or "Layer 2 segmentation," they're using OSI numbers. Vendors, certifications, and security tooling all default to OSI vocabulary.
- **TCP/IP** is better for *thinking about how networks actually work*. The protocols that run the internet were designed against the TCP/IP model, not OSI.

I'll mostly use OSI layer numbers because that's what the security industry uses. When the distinction matters, I'll call it out.

A historical note worth knowing: TLS doesn't fit neatly into either model. It sits somewhere between Layer 4 and Layer 7 depending on who you ask. Don't lose sleep over this.

---

## The map of the course

Here's how the rest of this course slots onto the path of a packet:

- **Module 2:** Layer 2 deep dive. Frames, MACs, switches, ARP, VLANs, and the attacks that live there.
- **Module 3:** Layer 3 deep dive. IP, routing, ICMP, and the attacks that live there.
- **Module 4:** Layer 4 deep dive. TCP, UDP, scanning, and the attacks that live there.
- **Module 5:** The boring infrastructure (DNS, DHCP, NAT) and how attackers abuse all of it.
- **Module 6:** Wireshark fluency. The skill that ties the whole stack together.
- **Module 7:** Routing and switching at scale. Firewalls, segmentation, blast radius.
- **Module 8:** Wireless. The Layer 1 and Layer 2 problems that look different on radio.
- **Module 9:** Pivot to endpoints. Active Directory, Windows networking, the enterprise reality.
- **Module 10:** AD attack paths. Kerberoasting, BloodHound, lateral movement.
- **Module 11:** Detection. What the defender sees while all of that is happening.
- **Module 12:** Capstone. Put it all together against a target environment.

Every module of this course connects back to a layer of the path you just walked.

---

## What to do next

Spin up Wireshark. Run `curl https://example.com`. Capture the traffic. Look at one of the captured frames and expand every layer in the Wireshark pane. You will see the same headers I described above, in the same order, on a real packet you generated yourself.

The next module dives into Layer 2: frames, MAC addresses, switches, and the first attack we'll actually run in a lab. If you want to be ready, install Wireshark and Containerlab on your machine before the next article drops.

---

*Cleartext is a course on networking and network security taught by Brandon Russell, an Air Force cyber instructor with an Ed.D. in Educational Leadership, an M.S. in Information Technology, and certifications including OSCP and CISSP.*
