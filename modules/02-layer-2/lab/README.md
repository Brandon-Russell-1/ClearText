# Module 2 Lab: ARP Spoofing on a Switched Segment

This lab spins up a small switched network on your machine, runs the ARP spoofing attack from the article against it, and then turns on the switch defenses that stop the attack. You can run the whole thing in five commands or step through it manually to watch each piece happen live.

---

## What you'll see

By the end of this lab you will have:

1. Captured normal Layer 2 traffic and identified every device on the segment by MAC.
2. Watched a victim's ARP cache get poisoned in real time by an attacker on the same wire.
3. Confirmed that the victim's traffic now flows through the attacker without the victim noticing anything is wrong.
4. Applied two real-world switch defenses (port-security and Dynamic ARP Inspection) and watched the same attack fail.

---

## Prerequisites

- **Docker** running on your machine (Docker Desktop on Windows/Mac, Docker Engine on Linux).
- **Containerlab** installed. One-line install: `bash -c "$(curl -sL https://get.containerlab.dev)"`.
- **Linux host or WSL2.** Containerlab needs Linux network namespaces and ebtables. On Windows, run everything from inside WSL2 (see [`docs/setup-windows.md`](../../../docs/setup-windows.md)).
- **Wireshark** is optional but recommended for the manual exploration steps.

---

## Topology

```
                  +-----------+
                  |  gateway  |  10.0.0.1
                  +-----+-----+
                        |
                  +-----+-----+
                  |  switch   |  Linux bridge inside a container
                  +-+---+---+-+
                    |   |   |
            +-------+   |   +-------+
            |           |           |
       +----+----+ +----+----+ +----+----+
       | victim  | |bystander| |attacker |
       |10.0.0.10| |10.0.0.11| |10.0.0.99|
       +---------+ +---------+ +---------+
```

Five containers on one broadcast domain (`10.0.0.0/24`):

| Node | Role |
|------|------|
| `switch` | A `nicolaka/netshoot` container with a Linux bridge wired to all four data interfaces. Acts as the L2 switch. |
| `gateway` | A normal endpoint at `10.0.0.1`. The thing the victim wants to talk to. |
| `victim` | A normal endpoint at `10.0.0.10`. The target of the attack. |
| `bystander` | A normal endpoint at `10.0.0.11`. Demonstrates that the attack only affects who the attacker targets, not the whole segment. |
| `attacker` | A normal endpoint at `10.0.0.99` with `dsniff` (`arpspoof`) installed. Runs the attack. |

> **Why a Linux bridge instead of OVS or a real switch image?** The Linux bridge is one container and zero registration. The same teaching points (MAC learning, port forwarding, port-security) apply identically. A future variant of this lab can swap in Open vSwitch or Arista cEOS-lab if you want experience with vendor CLIs; the article's content doesn't change.

---

## Quick start (the fast path)

```bash
# From the lab directory:
sudo containerlab deploy
./validate.sh all
sudo containerlab destroy
```

That's it. `validate.sh all` runs the check, the attack, and the defense end-to-end and prints PASS or FAIL at each step. Total time: about two minutes once images are pulled.

If you want to actually *learn* something, do it the slow way below.

---

## Walkthrough

### Step 1: Bring up the topology

```bash
sudo containerlab deploy
```

Containerlab pulls `nicolaka/netshoot`, spins up the five containers, wires them with veth pairs, runs the per-node `exec` hooks (assigning IPs, installing `dsniff` on the attacker, building the bridge on the switch), and prints a summary table.

Confirm everything is healthy:

```bash
./validate.sh check
```

You should see **PASS**: the victim can reach the gateway. If not, scroll up in the `containerlab deploy` output for any setup errors.

### Step 2: Look at normal traffic

Now do some manual exploration. Open three terminal panes and run these in parallel.

**Terminal 1 -- the victim's ARP cache:**

```bash
docker exec -it clab-cleartext-l2-victim ip neigh
```

Note the MAC the victim has cached for `10.0.0.1`. That should be the *real* gateway's MAC.

**Terminal 2 -- the switch's MAC address table (the CAM table):**

```bash
docker exec -it clab-cleartext-l2-switch bridge fdb show br br0
```

You'll see entries mapping each device's MAC to the bridge port (`eth1`, `eth2`, `eth3`, `eth4`) it lives behind. This is exactly what the article describes: the switch built this table by watching source MACs in incoming frames.

**Terminal 3 -- live capture on the switch:**

```bash
docker exec -it clab-cleartext-l2-switch tcpdump -i br0 -n -e
```

While that runs, generate some traffic from the victim:

```bash
docker exec clab-cleartext-l2-victim ping -c 3 10.0.0.1
```

Watch the captured frames. You'll see ICMP request and reply pairs, plus periodic ARP if any cache entries expire. Note the source and destination MACs on each frame and trace them back to who's who in the topology.

#### Optional: pipe the capture into Wireshark

If you have Wireshark installed (on Windows alongside WSL2, or natively on Linux/Mac), you can stream the capture into a real GUI:

```bash
# From inside WSL2 / Linux:
docker exec clab-cleartext-l2-switch tcpdump -i br0 -U -w - | wireshark -k -i -

# On Windows hosts running Wireshark.exe through WSL:
docker exec clab-cleartext-l2-switch tcpdump -i br0 -U -w - | wireshark.exe -k -i -
```

Generate traffic and watch the dissector pull every header apart. This is the article's content rendered in three colors.

### Step 3: Run the attack

```bash
./validate.sh attack
```

The script:

1. Pings the gateway from the victim, so the victim has a fresh ARP entry to be poisoned.
2. Records the victim's *current* gateway MAC (should be the real gateway).
3. Enables IP forwarding on the attacker so the victim doesn't notice connectivity break.
4. Launches `arpspoof` against the victim AND the gateway (both directions, so the attacker is on the full path).
5. Waits five seconds for the poison to take effect.
6. Re-checks the victim's gateway MAC (should now be the attacker's MAC).
7. Generates more victim traffic and confirms a matching packet appears on the attacker's interface.
8. Prints **PASS** if both checks succeeded.

Expected output ends with something like:

```
[PASS] ARP spoofing attack succeeded. Attacker is in the middle.
```

The attack is still running in the background after the script exits. The next step shows you how to see it live.

### Step 4: See the attack live

In one terminal, watch the attacker's interface:

```bash
docker exec -it clab-cleartext-l2-attacker tcpdump -i eth1 -n host 10.0.0.10
```

In another, generate steady traffic from the victim:

```bash
docker exec clab-cleartext-l2-victim sh -c \
    "while true; do curl -s -o /dev/null --max-time 1 http://10.0.0.1; sleep 1; done"
```

(The curl will fail to connect, that's fine. We just need outbound packets.)

You should see the victim's outbound packets appearing on the attacker's interface. The victim's kernel believes the attacker is the gateway, so frames addressed to `10.0.0.1` are physically delivered to `10.0.0.99` first, who forwards them to the real gateway.

Now compare ARP caches. On the victim:

```bash
docker exec clab-cleartext-l2-victim ip neigh show 10.0.0.1
```

The MAC in that output is the attacker's, not the gateway's. The victim has been lied to and has no idea.

On the bystander, just to prove the attack only affects the targeted host:

```bash
docker exec clab-cleartext-l2-bystander ip neigh show 10.0.0.1
```

The bystander still has the real gateway's MAC. The attack is precise: only the target was poisoned.

### Step 5: Apply the defense

```bash
./validate.sh defend
```

The script:

1. Stops the running `arpspoof` processes.
2. Clears the victim's and gateway's ARP caches so they re-learn from scratch.
3. Records every device's expected MAC and IP into `configs/macs.env`.
4. Runs `switch-secure.sh` on the switch, which applies two layers of `ebtables` rules:
   - **Port-security**: each switch port is locked to one source MAC. Frames with any other source MAC on that port are dropped.
   - **Dynamic ARP Inspection (DAI)**: each switch port is locked to one ARP-sender IP. ARP packets that lie about their sender IP are dropped.
5. Re-runs the attack against the now-hardened switch.
6. Verifies the victim's ARP cache stays correct AND no victim traffic reaches the attacker.
7. Prints **PASS** if both checks held.

The DAI rule is what specifically blocks ARP spoofing, because the spoof lives in the ARP payload, not in the Ethernet header. The article describes this defense as "port-security with ARP inspection" -- now you've seen what each piece actually does.

### Step 6: Inspect the defense

After `validate.sh defend` passes, look at the rules the switch is now enforcing:

```bash
docker exec clab-cleartext-l2-switch ebtables -L FORWARD --Lc
```

You'll see a counter on the DAI rule for the attacker's port go up every time `arpspoof` tries again, because every attempt is being silently dropped at the switch.

Compare this to a real switch CLI. On Cisco IOS, the equivalent is roughly:

```
interface FastEthernet0/4
 switchport port-security maximum 1
 switchport port-security mac-address sticky
ip arp inspection vlan 10
```

Three commands on a real switch. The same protection.

### Step 7: Tear down

```bash
sudo containerlab destroy
```

Topology is gone. No leftover state on your host.

---

## Troubleshooting

| Symptom | Probable cause |
|---------|----------------|
| `containerlab deploy` says "Cannot connect to the Docker daemon" | Docker isn't running. Start Docker Desktop or `systemctl start docker`. |
| `validate.sh check` reports the victim can't ping the gateway | The bridge probably didn't come up. Check `docker logs clab-cleartext-l2-switch` and `docker exec clab-cleartext-l2-switch ip link show br0`. |
| `validate.sh attack` reports the attack didn't succeed | Likely the victim's ARP cache wasn't populated before the attack. Re-run; the script forces a ping first but timing on slow hosts can race. |
| `validate.sh defend` reports the defense didn't hold | Confirm `ebtables -L FORWARD` on the switch shows the rules. If `ebtables` is not available, your kernel may not have bridge netfilter compiled in (rare on WSL2, but possible on minimal hosts). |
| `apk add dsniff` fails on attacker | The container couldn't reach Alpine's package mirror. Confirm `docker exec clab-cleartext-l2-attacker ping 8.8.8.8` works. |

If the lab gets into a weird state, the cleanest reset is:

```bash
sudo containerlab destroy --cleanup
sudo containerlab deploy
```

---

## What to take away

ARP spoofing has been a documented attack since the late 1990s. It still works against any default-configured switch in 2026 because the defenses (port-security, DAI, 802.1X) are off by default and require deliberate per-interface configuration. Every enterprise switch in the world has the features that would have stopped what you just watched. Most of them aren't using them.

The article describes this in the abstract. The lab made it real on hardware (well, on container-shaped hardware) you control. Move on to Module 3 and we follow the IP packet up out of the local segment and into the routing world.
