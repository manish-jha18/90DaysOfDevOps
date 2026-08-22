# Day 14 – Networking Fundamentals and Hands-on Checks

Target host for today: `google.com`. Used the same target across ping, traceroute, dig and curl so the results line up.

---

## Quick Concepts

### OSI vs TCP/IP

OSI has 7 layers and is a teaching model. TCP/IP has 4 and is what actually runs. They map onto each other roughly like this:

| OSI | TCP/IP | What lives there | Example |
|---|---|---|---|
| L7 Application | Application | The protocol the app speaks | HTTP, DNS, SSH |
| L6 Presentation | Application | Encoding, encryption | TLS, JSON |
| L5 Session | Application | Keeping a conversation open | TLS session resume |
| L4 Transport | Transport | Ports, reliable or not | TCP, UDP |
| L3 Network | Internet | Addressing and routing | IP, ICMP |
| L2 Data Link | Link | Local delivery on one network | Ethernet, ARP, MAC |
| L1 Physical | Link | Cables and radio | Copper, fibre, WiFi |

- The three top OSI layers collapse into one Application layer in TCP/IP, because in practice nobody separates them.
- L1 and L2 collapse into Link for the same reason.
- The layers that matter most day to day are **L3 (IP), L4 (TCP/UDP) and L7 (HTTP/DNS)**, which is also why most troubleshooting commands target exactly those.

### Where each protocol sits

- **IP** — L3. Handles addressing and getting a packet across networks. No guarantee of delivery.
- **TCP** — L4. Adds ports, ordering, retransmission and a connection handshake. Reliable, slower.
- **UDP** — L4. Ports and nothing else. Fire and forget. Used where speed beats reliability: DNS, video, metrics.
- **HTTP/HTTPS** — L7. Runs on top of TCP. HTTPS is HTTP wrapped in TLS.
- **DNS** — L7 protocol, usually over UDP port 53, falling back to TCP for large replies.

### One real example

`curl https://example.com` in layers, top down:

1. **L7** — DNS resolves `example.com` to an IP, then curl writes an HTTP `GET /`.
2. **L6/L5** — TLS handshake encrypts the connection on port 443.
3. **L4** — TCP opens the connection with a SYN, SYN-ACK, ACK handshake and guarantees the bytes arrive in order.
4. **L3** — IP puts source and destination addresses on each packet and routers forward it.
5. **L2/L1** — Ethernet or WiFi frames carry it to my router, then out over the physical link.

Every layer wraps the one above it. The failure being at a specific layer is what makes a diagnosis useful — "the site is down" is not actionable, "DNS resolves but TCP 443 times out" is.

---

## Hands-on checklist

### Identity

```
devops@testvm:~$ hostname -I
10.0.2.15 172.17.0.1
```

```
devops@testvm:~$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 08:00:27:a4:1e:c9 brd ff:ff:ff:ff:ff:ff
    inet 10.0.2.15/24 brd 10.0.2.255 scope global dynamic enp0s3
       valid_lft 84291sec preferred_lft 84291sec
3: docker0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 02:42:8f:3d:11:7b brd ff:ff:ff:ff:ff:ff
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
       valid_lft forever preferred_lft forever
```

**Observation:** Three interfaces. `lo` is the loopback at `127.0.0.1` and never leaves the machine. `enp0s3` is the real NIC at `10.0.2.15/24`. `docker0` at `172.17.0.1/16` is the bridge Docker created — that appeared on its own when I installed Docker on Day 08.

The `/24` and `/16` are the subnet sizes. `dynamic` on enp0s3 means DHCP handed out the address, and `valid_lft 84291sec` is the remaining lease, roughly 23 hours.

### Reachability

```
devops@testvm:~$ ping -c 4 google.com
PING google.com (142.250.183.174) 56(84) bytes of data.
64 bytes from bom12s15-in-f14.1e100.net (142.250.183.174): icmp_seq=1 ttl=115 time=14.2 ms
64 bytes from bom12s15-in-f14.1e100.net (142.250.183.174): icmp_seq=2 ttl=115 time=13.8 ms
64 bytes from bom12s15-in-f14.1e100.net (142.250.183.174): icmp_seq=3 ttl=115 time=15.1 ms
64 bytes from bom12s15-in-f14.1e100.net (142.250.183.174): icmp_seq=4 ttl=115 time=13.9 ms

--- google.com ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3005ms
rtt min/avg/max/mdev = 13.812/14.256/15.108/0.521 ms
```

**Observation:** 0% loss and an average of 14.2 ms with very little jitter (mdev 0.5 ms). A stable connection. `ping` already did a DNS lookup to get `142.250.183.174`, so a successful ping by hostname proves DNS and L3 connectivity in one command.

`ttl=115` is the remaining time-to-live. It started at 128 and dropped by one per router, so the reply crossed about 13 hops.

### Path

```
devops@testvm:~$ traceroute google.com
traceroute to google.com (142.250.183.174), 30 hops max, 60 byte packets
 1  _gateway (10.0.2.2)  0.412 ms  0.388 ms  0.361 ms
 2  192.168.1.1 (192.168.1.1)  2.104 ms  2.088 ms  2.061 ms
 3  100.64.12.1 (100.64.12.1)  8.442 ms  8.417 ms  8.390 ms
 4  * * *
 5  172.31.8.45 (172.31.8.45)  11.203 ms  11.188 ms  11.162 ms
 6  72.14.204.68 (72.14.204.68)  12.881 ms  12.855 ms  12.830 ms
 7  142.251.53.113 (142.251.53.113)  13.402 ms  13.377 ms  13.351 ms
 8  bom12s15-in-f14.1e100.net (142.250.183.174)  14.118 ms  14.092 ms  14.067 ms
```

**Observation:** 8 hops. Hop 1 is my VM's gateway, hop 2 my home router, hop 3 the ISP. The jump from 2 ms to 8 ms at hop 3 is where traffic leaves my house.

Hop 4 shows `* * *`. That is **not** a fault. Plenty of routers are configured not to reply to ICMP but still forward traffic perfectly — and the proof is that hops 5 to 8 answered. A timeout only matters if every hop after it also times out.

### Ports

```
devops@testvm:~$ ss -tulpn
Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
udp   UNCONN 0      0      127.0.0.53%lo:53         0.0.0.0:*
udp   UNCONN 0      0        10.0.2.15%enp0s3:68    0.0.0.0:*
tcp   LISTEN 0      4096     127.0.0.53%lo:53         0.0.0.0:*
tcp   LISTEN 0      128            0.0.0.0:22        0.0.0.0:*
tcp   LISTEN 0      128               [::]:22           [::]:*
```

**Observation:** SSH is listening on port 22 on all interfaces (`0.0.0.0` for IPv4 and `[::]` for IPv6). Port 53 is bound to `127.0.0.53` only — that is `systemd-resolved`, the local DNS stub. Being on the loopback address means nothing outside the machine can query it, which is what I want.

Port 68 is the DHCP client holding its lease. The flags: `-t` TCP, `-u` UDP, `-l` listening, `-p` process, `-n` numeric ports instead of names.

### Name resolution

```
devops@testvm:~$ dig google.com

; <<>> DiG 9.18.18-0ubuntu0.22.04.2-Ubuntu <<>> google.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 42817
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; QUESTION SECTION:
;google.com.			IN	A

;; ANSWER SECTION:
google.com.		238	IN	A	142.250.183.174

;; Query time: 4 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Thu Jun 25 10:22:41 UTC 2026
;; MSG RCVD: 55
```

**Observation:** Resolved to `142.250.183.174`, matching what ping showed. Status `NOERROR` means the lookup succeeded. TTL is 238 seconds, so this answer is cached and expires in about 4 minutes.

Query time of 4 msec means it came from the local cache at `127.0.0.53`. A fresh lookup would be 20 to 50 ms.

### HTTP check

```
devops@testvm:~$ curl -I https://google.com
HTTP/2 301
location: https://www.google.com/
content-type: text/html; charset=UTF-8
content-security-policy-report-only: object-src 'none';base-uri 'self'
date: Thu, 25 Jun 2026 10:24:03 GMT
expires: Thu, 25 Jun 2026 10:24:03 GMT
cache-control: private, max-age=0
server: gws
x-xss-protection: 0
x-frame-options: SAMEORIGIN
alt-svc: h3=":443"; ma=2592000
```

**Observation:** `301`, not `200`. A permanent redirect from `google.com` to `www.google.com`. Not an error — following it with `curl -IL` ends at a 200. Worth noticing, because a 301 in an automated health check that does not follow redirects would look like a failure.

`HTTP/2` is the protocol version, and `alt-svc: h3` advertises HTTP/3 over QUIC as an option.

### Connections snapshot

```
devops@testvm:~$ netstat -an | head -12
Active Internet connections (servers and established)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN
tcp        0      0 127.0.0.53:53           0.0.0.0:*               LISTEN
tcp        0     36 10.0.2.15:22            10.0.2.2:51884          ESTABLISHED
tcp6       0      0 :::22                   :::*                    LISTEN
udp        0      0 127.0.0.53:53           0.0.0.0:*
udp        0      0 10.0.2.15:68            0.0.0.0:*
```

```
devops@testvm:~$ netstat -an | grep -c LISTEN
4
devops@testvm:~$ netstat -an | grep -c ESTABLISHED
1
```

**Observation:** 4 listening, 1 established. The single established connection is my own SSH session from `10.0.2.2`. A quiet box, which is what I expect on a lab VM. On a busy web server this ratio would be the opposite — a handful of LISTEN and hundreds of ESTABLISHED.

`Send-Q 36` on that SSH connection is 36 bytes queued and not yet acknowledged. A Send-Q that keeps climbing means the other end has stopped reading.

---

## Mini task: port probe and interpret

**1. Pick a listening port.** From `ss -tulpn` above, SSH on port 22.

**2. Test it:**

```
devops@testvm:~$ nc -zv localhost 22
Connection to localhost (127.0.0.1) 22 port [tcp/ssh] succeeded!
```

```
devops@testvm:~$ nc -zv localhost 8080
nc: connect to localhost (127.0.0.1) port 8080 (tcp) failed: Connection refused
```

**3. Interpretation:** Port 22 is reachable — the TCP handshake completed, so sshd is genuinely accepting connections rather than merely appearing in a process list. Port 8080 gave **Connection refused**, which means nothing is listening there. Expected, since I have no app running on 8080.

The distinction that matters here:

- **Connection refused** — the packet reached the machine and the kernel actively rejected it because no process holds the port. The host is up; the service is not.
- **Connection timed out** — no reply at all. Something silently dropped the packet, almost always a firewall or security group.

Different causes, so different next steps. Refused means check `systemctl status <service>` and whether it is bound to the right address. Timed out means check `ufw status` and the cloud security group. This is exactly the Day 08 problem — Nginx was fine and the security group was closed, which presented as a timeout.

---

## Reflection

### Which command gives the fastest signal when something is broken?

`curl -I <url>`, if the thing is a web service. In one command it does the DNS lookup, opens TCP, completes the TLS handshake and returns a status code. Any of those failing produces a distinct error, so a single command narrows the problem to a layer:

- `Could not resolve host` → DNS, L7
- `Connection refused` → nothing listening, L4
- `Connection timed out` → firewall, L3/L4
- `SSL certificate problem` → TLS, L6
- `500` → the app itself, L7

For a non-HTTP service, `ping` first for L3 and then `nc -zv host port` for L4.

### What layer would I check next if DNS fails? If HTTP 500 shows up?

**DNS fails** — go *down* the stack. DNS is L7, so I verify the layers under it still work:
1. `ping 8.8.8.8` — is IP working at all (L3)
2. `cat /etc/resolv.conf` — am I pointed at a sensible resolver
3. `dig @8.8.8.8 example.com` — does a different resolver answer? If yes, my resolver is broken, not the network
4. `dig example.com NS` — does the domain even have working nameservers

**HTTP 500** — go *up* the stack. A 500 means everything below already worked: DNS resolved, TCP connected, TLS completed, the server received the request and the application threw an error. No point checking the network. I would go to application logs, then whatever the app depends on — database, cache, a downstream API. The distinction I want to keep: 4xx is the client's fault, 5xx is the server's.

### Two follow-up checks in a real incident

1. **Is it just me?** `curl -I` from a second machine or a different network. If it works elsewhere, the problem is local — my DNS, my firewall, my route — and I would waste an hour investigating a healthy server.
2. **When did it start, and what changed?** `journalctl -u <service> --since "1 hour ago"` and the deployment history. Most incidents follow a change. Matching the first error timestamp against the last deploy answers it faster than any packet capture.

---

## What I learned today

- Naming the layer turns a vague problem into a specific one. "The site is down" is not a diagnosis; "DNS resolves but TCP 443 times out" points at exactly one thing.
- **Connection refused and connection timed out mean genuinely different things.** Refused is a service problem, timed out is a firewall problem. That single distinction would have saved me time on Day 08.
- `* * *` in traceroute is usually a router declining to answer ICMP, not a broken hop. Only consecutive timeouts to the end matter.
- `ping <hostname>` succeeding proves DNS *and* L3 in one step, which makes it a good first command.
- A 301 is not a failure, but a naive health check that does not follow redirects will report it as one.
