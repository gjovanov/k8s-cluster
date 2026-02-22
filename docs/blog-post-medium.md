# From Bare Metal to Production K8s: COTURN, WebRTC, and Why I Ditched the Cloud

*A two-part guide on bootstrapping a high-performance Kubernetes cluster on a single Hetzner box and running production COTURN inside it.*

---

So here's the thing. I've been running [Roomler](https://github.com/gjovanov/roomler) — my open-source video conferencing & team collaboration tool (think "Slack on Crack") — on Docker for years. It worked great. Docker Compose up, grab a coffee, done.

But then people started asking me:

> "Hey Goran, how do I deploy COTURN in Kubernetes?"
> "Can you share your K8s setup?"
> "I keep getting ICE failures behind corporate NATs, help!"

And honestly? I had the same itch. My Docker setup was fine, but *fine* is the enemy of *great*. I wanted proper orchestration, automated failover, monitoring dashboards that would make NASA jealous, and — most importantly — I wanted to learn by doing.

So I did what any reasonable engineer would do: I rented a beefy Hetzner dedicated server, mass-produced VMs on it like a KVM factory, and built a full Kubernetes cluster from scratch.

Spoiler alert: it was totally worth it.

---

# Part 1: Bootstrapping a High-Performance K8s Cluster on Bare Metal

## Why Bare Metal? (a.k.a. The Cloud Bill Intervention)

Let me paint you a picture. You're running a couple of TURN servers, a WebRTC gateway, a Node.js app, MongoDB, Redis, Prometheus, Grafana... on AWS or GCP. Your monthly bill looks like a phone number. A *long* phone number.

Meanwhile, a Hetzner dedicated server with **10 vCPUs, 64 GB RAM, 2x NVMe SSDs**, and **two public IPs** costs about the same as your Netflix + Spotify subscription. Okay, maybe a bit more. But you get the point.

The tradeoff? You manage everything yourself. No managed Kubernetes, no EKS/GKE magic buttons. Just you, Ansible, and a terminal.

For our use case (WebRTC infra + a web app), this is actually *better*:
- **Full control over networking** — critical for TURN servers that need raw UDP/TCP access
- **No cloud NAT surprises** — you get real public IPs, no elastic IP juggling
- **Predictable performance** — no noisy neighbors stealing your CPU cycles
- **Way cheaper** — did I mention the phone number thing?

## The Big Picture

Before we dive into the weeds, let's see what we're building:

![Architecture Overview](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/01-architecture-overview.png)

One physical machine. Three virtual machines. A full K8s cluster. Two COTURN instances with separate public IPs. Monitoring. TLS. The whole nine yards.

Let me walk you through how we get there.

## Step 1: Virtualization — KVM and the VM Factory

Instead of running K8s directly on the host (which would be messy and inflexible), we use KVM/libvirt to spin up Ubuntu VMs with cloud-init. Think of it as our own mini-cloud, except we actually own the hardware.

![Vm Network Topology](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/02-vm-network-topology.png)

The VMs sit on a NAT bridge (`virbr1` on `10.10.10.0/24`). The host acts as the gateway. Internet traffic reaches the VMs through iptables DNAT rules on the host — we'll get to that spicy part later.

**Why cloud-init?** Because we're not animals. Cloud-init lets us pre-configure each VM with hostname, IP address, SSH keys, and packages — all from a YAML file. No clicking through installers, no manual SSH setup. Boot the VM, it's ready.

<details>
<summary><strong>Deep Dive: VM Provisioning with Ansible</strong></summary>

The Ansible role `vm-provision` does the heavy lifting:

1. Downloads the Ubuntu 22.04 cloud image (once)
2. Creates a qcow2 disk for each VM (backed by the cloud image)
3. Generates a cloud-init ISO with:
   - Hostname and static IP
   - SSH public key injection
   - Package pre-installation (curl, apt-transport-https)
4. Defines the VM in libvirt and starts it
5. Waits for SSH to become available

Each VM is defined in `inventory/group_vars/all.yml`:

```yaml
vms:
  - name: k8s-master
    vcpus: 2
    memory_mb: 4096
    disk_gb: 40
    ip: "10.10.10.10"
  - name: k8s-worker1
    vcpus: 4
    memory_mb: 8192
    disk_gb: 60
    ip: "10.10.10.11"
  - name: k8s-worker2
    vcpus: 4
    memory_mb: 8192
    disk_gb: 60
    ip: "10.10.10.12"
```

Want 5 workers? Add them to the list. Ansible handles the rest. Beautiful.

</details>

## Step 2: Kubernetes — kubeadm, Because We Like to Suffer (Just a Little)

With our VMs humming along, it's time to install Kubernetes. We use `kubeadm` — the official bootstrapper. No k3s, no microk8s, no managed solutions. The real deal.

The process is split into three Ansible roles:

| Role | Target | What it does |
|------|--------|-------------|
| `k8s-common` | All VMs | Install containerd, kubeadm, kubelet, kubectl, Helm |
| `k8s-master` | Master only | `kubeadm init`, install Cilium CNI, configure kubectl |
| `k8s-worker` | Workers only | `kubeadm join`, label nodes for scheduling |

<details>
<summary><strong>Deep Dive: Why Cilium over Flannel/Calico?</strong></summary>

For the CNI (Container Network Interface), we chose **Cilium** — and here's why:

1. **eBPF-powered** — network policies are enforced at the kernel level, not through iptables chains. Faster, more efficient.
2. **Replaces kube-proxy** — Cilium handles service load balancing natively. One less component to worry about.
3. **Hubble observability** — built-in network flow monitoring. When something breaks (and it will), you'll know exactly which packet went where.
4. **Future-proof** — Gateway API support, mutual TLS, bandwidth management. It's the Rolls-Royce of CNIs.

Installation is a one-liner via Helm:

```bash
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.10.10.10 \
  --set k8sServicePort=6443
```

The `kubeProxyReplacement=true` flag is the magic sauce — it tells Cilium to take over all kube-proxy duties.

</details>

After running the Ansible playbooks, we have a clean, 3-node Kubernetes cluster. `kubectl get nodes` shows all three nodes as `Ready`. Time to celebrate with a coffee. Actually, make it a beer — we earned it.

## Step 3: Monitoring — Because Flying Blind is Not an Option

What good is a cluster if you can't see what's happening inside it? We deploy the full **kube-prometheus-stack** via Helm:

- **Prometheus** — scrapes metrics from all pods, nodes, and K8s components
- **Grafana** — beautiful dashboards with pre-built views for cluster health
- **AlertManager** — sends email alerts via SendGrid when things go sideways

![Monitoring Stack](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/03-monitoring-stack.png)

We've configured alerts for the things that matter:

| Alert | When it fires |
|-------|--------------|
| COTURN Pod Down | Any COTURN pod goes missing |
| High CPU | > 85% for 10 minutes |
| High Memory | > 90% for 5 minutes |
| Disk Space Low | > 85% used |
| Pod Restarts | > 3 restarts per hour |

Access Grafana from your laptop:
```bash
make grafana-tunnel  # SSH tunnel to localhost:3000
```

## Step 4: TLS — Let's Encrypt All The Things

We use `acme.sh` with Cloudflare DNS-01 challenge for wildcard certificates. The beauty of DNS-01 is that you don't need to expose port 80 — perfect for our setup where the VMs are behind NAT.

```bash
# Automatic renewal runs daily via cron
# Deploy hook handles everything:
#   1. Copy cert to Docker nginx
#   2. Reload nginx
#   3. Update K8s TLS secret
#   4. Restart COTURN pods
```

One certificate, automatically renewed, automatically deployed everywhere. Set it and forget it.

---

# Part 2: Deploying COTURN in Kubernetes

Alright, now we're getting to the good stuff. This is the part everyone's been asking about.

## Why COTURN? (a.k.a. The NAT Problem Nobody Warned You About)

Here's a fun fact about WebRTC: it uses peer-to-peer connections. And here's a less fun fact: **most of the internet is behind NATs and firewalls**. Your users' browsers can't just magically find each other.

That's where TURN servers come in. When a direct connection (or a STUN-assisted connection) fails, the TURN server acts as a relay — all media flows through it. It's not ideal (adds latency), but it's the only thing that works for users behind symmetric NATs, corporate firewalls, or restrictive networks.

![Webrtc Nat Traversal](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/04-webrtc-nat-traversal.png)

Without TURN, roughly **10-15% of your users won't be able to join video calls**. On corporate networks, that number can be as high as **30-40%**. Ouch.

## The Challenge: COTURN + K8s Networking

Here's where it gets tricky. COTURN is not your average web service. It needs:

1. **Real public IP addresses** — not K8s ClusterIPs, not NodePorts. Actual routable IPs that clients can send UDP packets to.
2. **UDP port ranges** — 1,024 relay ports (we use 49152-50175) for media streams.
3. **Low latency** — every millisecond of extra latency = worse call quality.

This means we can't just slap COTURN in a regular K8s pod and call it a day. We need **`hostNetwork: true`** — the pod shares the host's network namespace directly. No NAT, no iptables mangling, just raw network access.

## The Architecture

We run **two COTURN instances**, one per worker node, each with its own dedicated public IP:

![Coturn Architecture](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/05-coturn-architecture.png)

Why two instances? Redundancy, my friend. If one goes down, the other still serves clients. Plus, we happen to have two public IPs — might as well use both.

## COTURN K8s Deployment — The Gory Details

Each COTURN instance is a K8s DaemonSet-like Deployment (1 replica, pinned to a specific node). Here's what the deployment looks like at a high level:

![Coturn K8S Deployment](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/06-coturn-k8s-deployment.png)

Each deployment gets its own ConfigMap because the `external-ip` mapping differs per instance:

```
# coturn-worker1 config
external-ip=94.130.141.98/10.10.10.11

# coturn-worker2 config
external-ip=94.130.141.74/10.10.10.12
```

This tells COTURN: "Hey, when a client asks for my address, tell them the *public* IP. But internally, I'm listening on the *private* IP." It's the magic glue that makes NAT traversal work.

<details>
<summary><strong>Deep Dive: The Full turnserver.conf</strong></summary>

Here's the complete COTURN configuration, explained line by line:

```ini
# Ports
listening-port=3478          # Standard TURN port (UDP + TCP)
tls-listening-port=5349      # TURNS (TURN over TLS)
alt-tls-listening-port=443   # TURNS on 443 (bypasses corporate firewalls)

# Relay port range (1024 ports per instance)
min-port=49152
max-port=50175

# Identity
realm=roomler.live

# NAT mapping: public IP / private IP
external-ip=94.130.141.98/10.10.10.11

# TLS (Let's Encrypt wildcard cert)
cert=/etc/coturn/tls/tls.crt
pkey=/etc/coturn/tls/tls.key

# Auth: TURN REST API (ephemeral credentials via HMAC-SHA1)
use-auth-secret
static-auth-secret=<your-secret-here>

# Security hardening
fingerprint               # Add fingerprint to STUN messages
no-multicast-peers        # Disable multicast relay
no-software-attribute     # Don't leak version info

# Performance
max-bps=0                 # No bandwidth limit
total-quota=0             # No quota limit
stale-nonce=600           # Nonce expires after 10 min

# Logging
verbose
log-file=stdout           # K8s captures stdout as pod logs

# CLI disabled (not needed in container)
no-cli
```

**Why `use-auth-secret` instead of `lt-cred-mech`?**

With `use-auth-secret` (TURN REST API mode), credentials are ephemeral — generated by your app server using HMAC-SHA1 and a shared secret. They expire after a configurable time. This is more secure than static username/password (lt-cred-mech), because:
- No hardcoded passwords
- Credentials rotate automatically
- Compromised credentials expire quickly

The client generates credentials like this:
```
username = "expiry_timestamp:label"
credential = Base64(HMAC-SHA1(shared_secret, username))
```

</details>

## The Networking Puzzle: iptables DNAT/SNAT

Our VMs are behind a NAT bridge (`10.10.10.0/24`). The internet can't reach them directly. We need iptables rules on the host to forward traffic:

![Iptables Dnat Snat Flow](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/07-iptables-dnat-snat-flow.png)

For each public IP, we forward:

| Traffic | Protocol | Destination |
|---------|----------|-------------|
| `:3478` (TURN) | TCP + UDP | Worker VM IP |
| `:5349` (TURNS) | TCP + UDP | Worker VM IP |
| `:49152-50175` (relay) | TCP + UDP | Worker VM IP |

<details>
<summary><strong>Deep Dive: The iptables Rules</strong></summary>

We create custom chains to keep things organized:

```bash
# Create custom chains
iptables -t nat -N COTURN_DNAT
iptables -t nat -N COTURN_SNAT

# Insert into PREROUTING and POSTROUTING
iptables -t nat -I PREROUTING -j COTURN_DNAT
iptables -t nat -I POSTROUTING -j COTURN_SNAT

# Worker 1 (IP: 94.130.141.98 → 10.10.10.11)
iptables -t nat -A COTURN_DNAT -d 94.130.141.98 -p udp --dport 3478 -j DNAT --to 10.10.10.11
iptables -t nat -A COTURN_DNAT -d 94.130.141.98 -p tcp --dport 3478 -j DNAT --to 10.10.10.11
iptables -t nat -A COTURN_DNAT -d 94.130.141.98 -p tcp --dport 5349 -j DNAT --to 10.10.10.11
iptables -t nat -A COTURN_DNAT -d 94.130.141.98 -p udp -m multiport --dports 49152:50175 -j DNAT --to 10.10.10.11
iptables -t nat -A COTURN_DNAT -d 94.130.141.98 -p tcp -m multiport --dports 49152:50175 -j DNAT --to 10.10.10.11

# SNAT for return traffic
iptables -t nat -A COTURN_SNAT -s 10.10.10.11 -j SNAT --to-source 94.130.141.98

# (Same pattern for Worker 2 with 94.130.141.74 → 10.10.10.12)
```

These rules are persisted via a systemd service that restores them on boot. Docker restarts can sometimes flush iptables, so we also hook into Docker's restart to re-apply them.

**Pro tip:** Be very careful with iptables rules when you also have Docker and K8s on the same host. All three manage iptables chains, and they can step on each other's toes. Our approach of using custom chain names (`COTURN_DNAT`, `COTURN_SNAT`) keeps things isolated and easy to debug.

</details>

## Testing COTURN

Deployment is only half the battle. You need to verify it actually works. We provide a `coturn_test.html` file that you can open in your browser:

1. Enter your shared secret
2. Click "Test All URLs"
3. Watch the relay candidates appear (or not!)

The test covers all TURN/TURNS endpoints:

| URL | Protocol | What it tests |
|-----|----------|--------------|
| `turn:IP1:3478` | UDP | Standard TURN on first IP |
| `turn:IP2:3478` | UDP | Standard TURN on second IP |
| `turn:IP1:3478?transport=tcp` | TCP | TURN over TCP |
| `turns:hostname:5349` | TLS | Encrypted TURN |
| `turns:hostname:443` | TLS | TURN on HTTPS port (firewall bypass) |

If all tests show relay candidates — congratulations, your COTURN deployment is solid!

## Putting It All Together

The entire deployment is automated with Ansible and runs in 10 phases:

![Deployment Phases](https://raw.githubusercontent.com/gjovanov/k8s-cluster/master/docs/diagrams/08-deployment-phases.png)

From zero to a fully operational K8s cluster with production COTURN in about 20 minutes of Ansible runtime. Not bad, eh?

```bash
# The whole thing
git clone https://github.com/gjovanov/k8s-cluster.git
cd k8s-cluster
cp .env.example .env && vi .env  # add your secrets
make bootstrap                    # sit back and relax
make verify                       # confirm everything works
```

## Lessons Learned (The Hard Way)

Let me save you some pain. Here are the gotchas that bit me during this journey:

**1. COTURN image matters more than you think.**
I started with `instrumentisto/coturn:4.5.2` and spent hours debugging `use-auth-secret` failures. Turns out that old version had bugs with parsing the shared secret. Switching to the official `coturn/coturn:latest` (4.8.x) fixed it immediately. Use the official image. Always.

**2. iptables and Docker are frenemies.**
Docker manages its own iptables chains. When Docker restarts, it can flush your custom rules. Solution: a systemd service that re-applies COTURN rules after Docker starts. Trust me on this one.

**3. `turnutils_uclient` lies to you.**
When testing COTURN with `use-auth-secret`, the `turnutils_uclient` tool doesn't properly implement the TURN REST API. It'll say "cannot find credentials" even when everything is configured correctly. Test with a real browser instead. The `coturn_test.html` file is your friend.

**4. TLS on port 443 is a game-changer.**
Many corporate firewalls block everything except ports 80 and 443. By offering TURNS on port 443, you dramatically increase the number of users who can successfully connect. It's the single biggest improvement you can make for WebRTC connectivity.

**5. DNS wildcard records can bite you.**
If you have a wildcard `*.yourdomain.com` pointing to an old IP, and you create explicit A records for subdomains, the explicit records take priority — but *only for those subdomains*. Everything else still resolves to the wildcard IP. I lost an embarrassing amount of time debugging why `janus.roomler.live` was resolving to a completely wrong server.

## What's Next?

In the companion blog post, we cover how to migrate the full Roomler application stack (MongoDB, Redis, Janus, Node.js app) from Docker into this K8s cluster — with zero downtime and zero data loss.

Check it out: [From Docker to K8s: Migrating a Full WebRTC Stack Without Dropping a Single Call](https://github.com/gjovanov/roomler-deploy/blob/main/docs/blog-post.md)

And of course, the source code for everything you've read here is fully open source:

- **K8s Cluster setup:** [github.com/gjovanov/k8s-cluster](https://github.com/gjovanov/k8s-cluster)
- **Roomler app:** [github.com/gjovanov/roomler](https://github.com/gjovanov/roomler)
- **Live demo:** [roomler.live](https://roomler.live)

If you found this useful, star the repos, share with your WebRTC-curious friends, and if you run into issues — open a GitHub issue. I actually read them. Usually with coffee.

Talk to you soon!
