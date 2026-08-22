# Day 15 – Networking Concepts: DNS, IP, Subnets and Ports

Concept day building on Day 14. Less running commands, more understanding what the output actually meant.

---

## Task 1: DNS – how names become IPs

### What happens when I type google.com in a browser

The browser checks its own cache, then the OS cache, then `/etc/hosts`. If none of those have the answer it asks the configured resolver (on my VM that is `systemd-resolved` at `127.0.0.53`, which forwards to my router or ISP).

If the resolver has no cached answer it walks the DNS hierarchy: a **root server** points it at the `.com` **TLD servers**, those point at Google's **authoritative nameservers**, and those return the actual A record. The resolver caches the answer for the length of the TTL and hands the IP back.

The browser then opens a TCP connection to that IP on port 443, completes the TLS handshake, and sends `GET /`. DNS is only the lookup step — it does no data transfer at all.

The whole point is caching. A cold lookup crosses several servers; a warm one is answered from memory in a few milliseconds.

### Record types

| Record | What it does |
|---|---|
| `A` | Maps a hostname to an IPv4 address. The most common record |
| `AAAA` | Same, but IPv6. Called "quad A" because IPv6 addresses are four times longer |
| `CNAME` | An alias pointing one name at another name, not at an IP. `www.example.com → example.com` |
| `MX` | Where to deliver email for this domain, with a priority number. Lower priority wins |
| `NS` | Which nameservers are authoritative for this domain |

Two things worth remembering: a `CNAME` cannot sit at the root of a domain (`example.com` itself), which is why providers invented ALIAS records. And a `CNAME` costs an extra lookup, since the resolver has to resolve the target name too.

### dig output

```
devops@testvm:~$ dig google.com

; <<>> DiG 9.18.18-0ubuntu0.22.04.2-Ubuntu <<>> google.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 51203
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; QUESTION SECTION:
;google.com.			IN	A

;; ANSWER SECTION:
google.com.		112	IN	A	142.250.183.174

;; Query time: 3 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Fri Jun 26 09:41:18 UTC 2026
;; MSG RCVD: 55
```

**The A record:** `142.250.183.174`
**The TTL:** `112` seconds — the number between the name and `IN`. It counts down as the cached entry ages. Running `dig` again immediately shows a lower number, which is a neat way to prove caching is real:

```
devops@testvm:~$ dig google.com +short
142.250.183.174

devops@testvm:~$ dig google.com | grep "^google.com"
google.com.		94	IN	A	142.250.183.174
```

112 down to 94 in 18 seconds. When it reaches 0 the resolver fetches a fresh answer.

**Why TTL matters in practice:** if I change a DNS record with a TTL of 3600, some users keep hitting the old IP for up to an hour. Before a planned migration you lower the TTL to 60 a day in advance, then cut over.

```
devops@testvm:~$ dig google.com MX +short
10 smtp.google.com.

devops@testvm:~$ dig google.com NS +short
ns2.google.com.
ns1.google.com.
ns3.google.com.
ns4.google.com.
```

---

## Task 2: IP addressing

### What is an IPv4 address

32 bits, written as four decimal numbers (octets) separated by dots. Each octet is 8 bits, so 0 to 255.

```
192  .  168  .  1  .  10
 ↓       ↓      ↓     ↓
11000000.10101000.00000001.00001010
```

Part of the address identifies the **network** and part identifies the **host** on it. The subnet mask is what says where the split falls. Total space is 2^32, about 4.3 billion addresses — which sounded enormous in 1981 and ran out in 2011. That shortage is why NAT and private ranges exist, and ultimately why IPv6 exists.

### Public vs private

**Public** IPs are globally unique and routable on the internet. They are allocated by regional registries and you generally rent one from a provider.
Example: `142.250.183.174` (google.com)

**Private** IPs are only valid inside one network. They are reused by millions of networks at once and routers on the internet drop them. To reach the internet they go through NAT, where the router swaps the private source address for its own public one.
Example: `10.0.2.15` (my VM)

This is why my VM says `10.0.2.15` but a website sees my router's public IP. And it is why "the server can't be reached" sometimes just means someone handed out a private address to something outside the network.

### Private ranges

| Range | CIDR | Addresses | Typical use |
|---|---|---|---|
| `10.0.0.0` – `10.255.255.255` | `10.0.0.0/8` | ~16.7 million | Large corporate networks, AWS VPCs |
| `172.16.0.0` – `172.31.255.255` | `172.16.0.0/12` | ~1 million | Medium networks, Docker's default bridge |
| `192.168.0.0` – `192.168.255.255` | `192.168.0.0/16` | 65,536 | Home routers, small offices |

Worth noting `172.16.0.0/12` stops at `172.31`, not `172.255`. `172.32.0.1` is a public address. This catches people out.

Two more special ranges: `127.0.0.0/8` is loopback (only `127.0.0.1` is usually used) and `169.254.0.0/16` is link-local — if a machine shows a `169.254.x.x` address it means DHCP failed and it gave up.

### My own addresses

```
devops@testvm:~$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    inet 127.0.0.1/8 scope host lo
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 08:00:27:a4:1e:c9 brd ff:ff:ff:ff:ff:ff
    inet 10.0.2.15/24 brd 10.0.2.255 scope global dynamic enp0s3
3: docker0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 02:42:8f:3d:11:7b brd ff:ff:ff:ff:ff:ff
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
```

| Interface | Address | Type |
|---|---|---|
| `lo` | `127.0.0.1/8` | Loopback, never leaves the machine |
| `enp0s3` | `10.0.2.15/24` | **Private** — inside the `10.0.0.0/8` range |
| `docker0` | `172.17.0.1/16` | **Private** — inside the `172.16.0.0/12` range |

Every address on this box is private. Nothing here is reachable from the internet directly, which matches what I saw on Day 08: the EC2 box knew itself as `172.31.14.88` while the world reached it on `13.234.19.204`.

---

## Task 3: CIDR and subnetting

### What /24 means

The number after the slash is **how many bits belong to the network**. The rest belong to hosts.

In `192.168.1.0/24`, the first 24 bits are the network, leaving 8 bits for hosts:

```
192.168.1.0/24
11000000.10101000.00000001 . 00000000
└────── network (24) ─────┘  └host (8)┘
```

So every address from `192.168.1.0` to `192.168.1.255` is on this network, and only the last octet varies. A bigger slash number means a *smaller* network, which is backwards from how it first reads.

### The filled table

| CIDR | Subnet Mask | Total IPs | Usable Hosts |
|------|-------------|-----------|--------------|
| /24  | 255.255.255.0   | 256        | 254        |
| /16  | 255.255.0.0     | 65,536     | 65,534     |
| /28  | 255.255.255.240 | 16         | 14         |

**The maths:** host bits = 32 − CIDR. Total = 2^(host bits). Usable = total − 2.

- `/24` → 8 host bits → 2^8 = 256 → 254 usable
- `/16` → 16 host bits → 2^16 = 65,536 → 65,534 usable
- `/28` → 4 host bits → 2^4 = 16 → 14 usable

**Why minus 2:** the first address is the network address itself and the last is the broadcast address. Neither can be given to a host. In `192.168.1.0/24` that is `192.168.1.0` (network) and `192.168.1.255` (broadcast), leaving `.1` to `.254`.

AWS is stricter still and reserves 5 addresses per subnet, so a `/28` there gives 11 usable, not 14. Caught me out when reading VPC docs.

### Why do we subnet

**Fewer wasted addresses.** Giving a 6-server rack a `/16` wastes 65,000 addresses. A `/28` gives 14, which fits.

**Containment of broadcasts.** Broadcast traffic reaches every host in a subnet. One flat network with thousands of machines means every machine processes every broadcast.

**Security boundaries.** This is the big one in cloud work. Public subnets hold load balancers, private subnets hold app servers, and databases sit in a subnet with no internet route at all. Security group rules are written against these ranges — "allow 3306 only from `10.0.1.0/24`" is only expressible because the network is subnetted.

**Cleaner routing.** Routers match on network prefixes. One route entry for `10.0.1.0/24` covers 254 hosts.

A typical VPC layout:

```
VPC            10.0.0.0/16     65,536 addresses
├── Public     10.0.1.0/24     254 — load balancer, NAT gateway
├── App        10.0.2.0/24     254 — application servers, no public IP
└── Database   10.0.3.0/24     254 — RDS, reachable only from the app subnet
```

---

## Task 4: Ports

### What is a port and why

An IP address gets a packet to the right **machine**. A port gets it to the right **program** on that machine.

One server can run a web server, SSH and a database on a single IP. Without ports the kernel would have no way to know which process a packet belongs to. A port is a 16-bit number, so 0 to 65535.

A connection is identified by four things together — source IP, source port, destination IP, destination port. That is why thousands of browsers can all connect to port 443 on the same server without confusion: each has a different source port.

The ranges:
- **0–1023** — well-known ports. Binding one requires root, which is why a web server needs root to start on port 80.
- **1024–49151** — registered, used by applications like MySQL and Redis.
- **49152–65535** — ephemeral. What the OS hands your browser as a source port.

### Common ports

| Port | Service | Notes |
|------|---------|-------|
| 22   | SSH | Remote shell. Also carries `scp` and `sftp` |
| 80   | HTTP | Unencrypted web. Usually just redirects to 443 |
| 443  | HTTPS | HTTP over TLS. The default for anything public |
| 53   | DNS | Name resolution. UDP normally, TCP for large replies and zone transfers |
| 3306 | MySQL / MariaDB | Should never be exposed to the internet |
| 6379 | Redis | No authentication by default — exposing this is a well-known way to get compromised |
| 27017| MongoDB | Same warning as Redis |

The last three are the ones that matter most in DevOps. They belong in a private subnet, reachable only from the application tier.

### Matching listening ports to services

```
devops@testvm:~$ ss -tulpn
Netid State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process
udp   UNCONN 0      0       127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=389,fd=14))
udp   UNCONN 0      0      10.0.2.15%enp0s3:68       0.0.0.0:*     users:(("systemd-network",pid=387,fd=19))
tcp   LISTEN 0      4096    127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=389,fd=15))
tcp   LISTEN 0      128           0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=812,fd=3))
tcp   LISTEN 0      128              [::]:22            [::]:*     users:(("sshd",pid=812,fd=4))
```

**Match 1 — port 22 → `sshd` (PID 812).** Listening on `0.0.0.0`, meaning every interface, so it accepts connections from outside. Correct for SSH.

**Match 2 — port 53 → `systemd-resolve` (PID 389).** Bound to `127.0.0.53` only, so it is reachable from this machine and nowhere else. This is the local DNS stub resolver, not a public DNS server.

**Match 3 — port 68 → `systemd-network`.** The DHCP client holding the lease on the address.

The bind address is the detail worth reading. `0.0.0.0:22` is exposed to the network; `127.0.0.53:53` is not. A service that should be internal but shows `0.0.0.0` is a finding.

---

## Task 5: Putting it together

### What happens in `curl http://myapp.com:8080`

**DNS (L7)** resolves `myapp.com` to an IP via an A record, subject to its TTL. **IP (L3)** routes packets to that address, and whether it is public or private determines if it is reachable from where I am. **TCP (L4)** completes a three-way handshake to port 8080 — explicit, because it is not the default 80. **HTTP (L7)** then sends the request over that connection and gets a status code back. No TLS anywhere, since this is `http://` — the traffic is in plain text.

The `:8080` also tells me something operationally: a non-privileged port, so the app runs as a normal user rather than root. Commonly a container or a service behind a reverse proxy.

### App cannot reach a database at 10.0.1.50:3306

`10.0.1.50` is private, so this is inside the network. `3306` is MySQL. Checks in order, cheapest first:

**1. Is it DNS or the network?** The IP is already literal, so DNS is not involved. That eliminates a whole category immediately.

**2. Is the host reachable at L3?**
```
ping -c 3 10.0.1.50
```
Fails → routing or subnet problem. Succeeds → the host is up, move to L4.

**3. Is the port open at L4?**
```
nc -zv 10.0.1.50 3306
```
This is the command that splits the problem in two:
- **Connection refused** → the host is up but MySQL is not listening. Check `systemctl status mysql`, and check `bind-address` in `my.cnf` — a default of `127.0.0.1` means it only accepts local connections, which is a very common cause.
- **Connection timed out** → something is silently dropping packets. A security group, a NACL, or `ufw`. Check that the database's security group allows 3306 inbound from the app's subnet.

**4. Is it the application layer?** If `nc` connects, the network is fine and the problem is credentials, the database name, connection pool exhaustion or a schema issue. Application logs from there.

**5. Did anything change?** Check recent deploys and security group edits. In practice this is often the fastest route to the answer.

The reasoning that makes this quick is the same as Day 14: refused and timed out are different failures with different owners. Refused is the database team's problem, timed out is the network team's.

---

## What I learned

**1. The slash number is a bit count, and everything follows from that.** Host bits = 32 − CIDR, total = 2^host bits, usable = total − 2. Once I had that, `/28` giving 14 hosts stopped needing a calculator. It also explains why a bigger slash means a smaller network.

**2. Ports are how one IP serves many programs, and the bind address matters as much as the port.** `0.0.0.0:22` is open to the network while `127.0.0.53:53` is local-only. Reading only the port number and not the address it is bound to misses half the picture — which is exactly the difference between a database that is fine and one that is exposed.

**3. TTL is an operational concern, not a detail.** A record with a 3600-second TTL means an hour of users hitting the old IP after a change. Lowering the TTL a day before a migration is a real step in a real runbook.

**Two extras:**

- Private ranges are worth memorising, particularly that `172.16.0.0/12` ends at `172.31` and not `172.255`.
- `169.254.x.x` means DHCP failed. That address is a diagnosis on its own.
