# Redis Sentinel: High Availability, Quorum Consensus & mTLS Security Guide

> **Topology:** 6 Nodes (1 Master + 2 Replicas + 3 Dedicated Sentinels)  
> **Environment:** AlmaLinux 9 Virtual Machines on OrbStack  
> **Engine:** Redis v8.x (64-bit)  
> **Security Profile:** Mutual TLS (mTLS) Encryption + Dual-Layer Symmetrical Authentication  
> **Ports:** Redis TLS (`6379`), Sentinel TLS (`26379`), Plaintext Ports Disabled (`port 0`)

---

## Table of Contents
1. [Project Overview (In Simple Terms)](#1-project-overview-in-simple-terms)
   - [What is Redis?](#what-is-redis)
   - [What is Master-Replica Replication?](#what-is-master-replica-replication)
   - [The Problem with Standard Replication (The Need for Sentinel)](#the-problem-with-standard-replication-the-need-for-sentinel)
   - [What is Redis Sentinel and Why Do We Need It?](#what-is-redis-sentinel-and-why-do-we-need-it)
2. [Technical Deep Dive: How Redis Sentinel Works](#2-technical-deep-dive-how-redis-sentinel-works)
   - [Data Layer vs. Consensus Monitoring Layer](#data-layer-vs-consensus-monitoring-layer)
   - [Heartbeat, SDOWN, and ODOWN State Transitions](#heartbeat-sdown-and-odown-state-transitions)
   - [Quorum Consensus & Split-Brain Prevention](#quorum-consensus--split-brain-prevention)
   - [Sentinel Leader Election & Automatic Failover Sequence](#sentinel-leader-election--automatic-failover-sequence)
3. [Cryptographic Security Profile (mTLS & Authentication)](#3-cryptographic-security-profile-mtls--authentication)
4. [Lab Architecture & Service Topology Map](#4-lab-architecture--service-topology-map)
5. [Automation Scripts Breakdown](#5-automation-scripts-breakdown)
6. [Step-by-Step Deployment Guide](#6-step-by-step-deployment-guide)
7. [Operational Verification & Failover Drills](#7-operational-verification--failover-drills)
8. [Command Reference](#8-command-reference)

---

## 1. Project Overview (In Simple Terms)

### What is Redis?
Redis is an ultra-fast, in-memory data store. Instead of reading and writing data to slow physical storage drives (HDDs/SSDs), it keeps all data in system **RAM**. This allows Redis to execute operations in sub-milliseconds, making it the industry standard for caching, session stores, real-time analytics, and message queues.

### What is Master-Replica Replication?
In standard Redis deployments, you configure a **Master** node and one or more **Replica** (slave) nodes:
- The **Master** accepts all client write operations (`SET`, `HSET`, `LPUSH`).
- The **Replicas** continuously copy data from the master asynchronously.
- Clients can read from replicas, which distributes read traffic across multiple machines and keeps a hot copy of the dataset ready.

### The Problem with Standard Replication (The Need for Sentinel)
While standard replication provides data copies, **it provides zero automated recovery**:
1. **Replicas cannot promote themselves:** If the master server crashes, the replicas continue serving read traffic, but the entire system becomes read-only. No new data can be written.
2. **Manual Failover Downtime:** A system administrator must be alerted, log into the servers, manually pick a healthy replica, execute `REPLICAOF NO ONE` to make it a master, re-point the remaining replicas, and update application configuration files with the new IP address.
3. **The Result:** Even a minor master crash results in 15 to 30 minutes of complete write outage.

### What is Redis Sentinel and Why Do We Need It?
**Redis Sentinel** is an independent, distributed monitoring and failover management system designed to eliminate downtime:
- **Continuous Health Monitoring:** Dedicated Sentinel processes run independently from the data nodes, continuously checking if the master and replicas are healthy.
- **Automated Failover:** If the master node becomes unresponsive, Sentinels communicate with each other, agree that the master is dead by reaching a **Quorum**, elect a leader, and automatically promote the best replica to become the new master.
- **Configuration Provider:** Applications do not hardcode the master's IP address. Instead, applications query Sentinels to automatically discover the current active master.
- **Self-Healing:** If the old, crashed master recovers hours later, Sentinels reconfigure it as a replica of the new master so it rejoins the cluster seamlessly.
- **Downtime:** The entire failover process completes in **under 2 to 3 seconds**, with zero human intervention.

---

## 2. Technical Deep Dive: How Redis Sentinel Works

```
                         Client Applications
                                  |
            (Discovery & Health Query: Port 26379 TLS)
                                  v
+-------------------------------------------------------------------+
|                     Sentinel Consensus Layer                      |
|                                                                   |
|   +------------------+     +------------------+     +------------------+
|   |    Sentinel 1    | <-> |    Sentinel 2    | <-> |    Sentinel 3    |
|   |   redis-node-4   |     |   redis-node-5   |     |   redis-node-6   |
|   +------------------+     +------------------+     +------------------+
+-------------------------------------------------------------------+
                                  |
                       (Monitors / Orchestrates)
                                  v
+-------------------------------------------------------------------+
|                        Redis Data Layer                           |
|                                                                   |
|                      +--------------------+                       |
|                      |    Redis Master    |                       |
|                      |    redis-node-1    |                       |
|                      +--------------------+                       |
|                                |                                  |
|                  +-------------+-------------+                    |
|                  | (Asynchronous Replication)|                    |
|                  v                           v                    |
|        +--------------------+     +--------------------+          |
|        |   Redis Replica 1  |     |   Redis Replica 2  |          |
|        |    redis-node-2    |     |    redis-node-3    |          |
|        +--------------------+     +--------------------+          |
+-------------------------------------------------------------------+
```

### Data Layer vs. Consensus Monitoring Layer
The architecture physically separates data processing from failover orchestration:
- **Data Layer (Nodes 1, 2, 3):** Runs `redis-server` on port `6379`. Node 1 is the Master; Nodes 2 and 3 are Replicas streaming dataset changes over TLS-encrypted replication links (`tls-replication yes`).
- **Sentinel Consensus Layer (Nodes 4, 5, 6):** Runs `redis-sentinel` on port `26379`. These nodes hold no dataset in memory; their sole responsibility is health evaluation, mutual consensus, and orchestrating failover.

### Heartbeat, SDOWN, and ODOWN State Transitions
Sentinels track node health through deterministic state transitions:
1. **Heartbeat (`PING`):** Every Sentinel transmits a `PING` packet to the master, replicas, and peer sentinels every `1000ms`.
2. **Subjective Down (`sdown`):** If a node does not reply with a valid response within `down-after-milliseconds` (configured at `5000ms`), the observing Sentinel flags the node as `sdown`. This is a local, subjective observation.
3. **Objective Down (`odown`):** The observing Sentinel queries peer Sentinels using `SENTINEL is-master-down-by-addr`. When a sufficient number of Sentinels (matching or exceeding the configured **Quorum**) confirm the outage, the state is upgraded to `odown`.

### Quorum Consensus & Split-Brain Prevention
- **Quorum** is the minimum number of Sentinels that must agree a master is unreachable before initiating failover.
- In our 3-Sentinel deployment, the **Quorum is set to 2**:
  - If a temporary network glitch disconnects 1 Sentinel from the master, that Sentinel cannot trigger an accidental failover because it cannot obtain a second confirmation.
  - An odd number of Sentinels (3) ensures a strict majority ($N/2 + 1 = 2$) can always be achieved, eliminating tie-breaks and split-brain scenarios.

### Sentinel Leader Election & Automatic Failover Sequence
Once `odown` is reached, Sentinels execute the following failover sequence:
1. **Leader Election:** Sentinels run a Raft-style election epoch. The Sentinel that detected `odown` requests votes. Once a Sentinel secures a majority vote (at least 2 votes), it becomes the **Failover Leader**.
2. **Replica Selection:** The Leader Sentinel evaluates available replicas to pick the healthiest candidate using deterministic criteria:
   - Eliminates replicas disconnected from the master for too long (rejecting stale data).
   - Compares configured `replica-priority` (lowest priority value is selected; `0` excludes from election).
   - Compares `replication-offset` (the replica that processed the highest byte offset from the master is selected).
   - Tie-breaker: Lexicographical comparison of the node `runid`.
3. **Promotion:** The Leader Sentinel sends `REPLICAOF NO ONE` to the selected replica, elevating it to Master.
4. **Reconfiguration:** The Leader Sentinel sends `REPLICAOF <new-master-ip> 6379` to the other replicas.
5. **Notification:** Sentinels publish a `+switch-master mymaster <old-ip> 6379 <new-ip> 6379` message over the `__sentinel__:hello` Pub/Sub channel to notify all connected client applications.
6. **Demotion of Recovered Master:** The old master's configuration is rewritten in `sentinel.conf`. When it comes back online, Sentinels issue a `REPLICAOF` command, cleanly incorporating it as a replica.

---

## 3. Cryptographic Security Profile (mTLS & Authentication)

The lab implements an enterprise security baseline across both the data and consensus layers:

```
[Client / Peer]  ---(Mutual TLS: Handshake & Client Cert Verification)--->  [Target Service]
                 ---(AUTH: RedisMasterPass2026! / SentinelPeerPass2026!)-->  [Command Execution]
```

1. **Mutual TLS (mTLS) Encryption:**
   - A dedicated 4096-bit private Certificate Authority (`ca.key`, `ca.crt`) issues signed X.509 certificates.
   - Certificates feature **Subject Alternative Names (SANs)** covering all 6 VM internal IP addresses.
   - Plaintext TCP ports are disabled (`port 0`). Only `tls-port 6379` and `tls-port 26379` accept connections. Any unencrypted traffic is dropped at the TCP layer.
   - Master-Replica replication (`tls-replication yes`) and Sentinel consensus gossip (`sentinel tls-replication yes`) run strictly over encrypted TLS tunnels.
2. **Dual-Layer Symmetrical Authentication:**
   - **Data Layer:** Symmetrical `requirepass "RedisMasterPass2026!"` and `masterauth "RedisMasterPass2026!"` directives are applied across all data nodes, ensuring mutual authentication persists during and after failovers.
   - **Consensus Layer:** Protected via `sentinel auth-pass mymaster "RedisMasterPass2026!"` and `sentinel sentinel-user` / `sentinel-pass "SentinelPeerPass2026!"`.

---

## 4. Lab Architecture & Service Topology Map

The lab runs on 6 AlmaLinux 9 Virtual Machines provisioned in OrbStack:

| VM Name | Host Role | Service Process | Port | Protocol | Security Scope |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`redis-node-1`** | **Master** | `redis-server` | `6379` | TLS | Primary write node; replicates to nodes 2 & 3 |
| **`redis-node-2`** | **Replica 1** | `redis-server` | `6379` | TLS | Read copy; eligible for promotion on failover |
| **`redis-node-3`** | **Replica 2** | `redis-server` | `6379` | TLS | Read copy; eligible for promotion on failover |
| **`redis-node-4`** | **Sentinel 1** | `redis-sentinel`| `26379` | TLS | Independent monitor & consensus voter (Quorum: 2) |
| **`redis-node-5`** | **Sentinel 2** | `redis-sentinel`| `26379` | TLS | Independent monitor & consensus voter (Quorum: 2) |
| **`redis-node-6`** | **Sentinel 3** | `redis-sentinel`| `26379` | TLS | Independent monitor & consensus voter (Quorum: 2) |

---

## 5. Automation Scripts Breakdown

The repository contains 4 progressive automation scripts:

### 1. `01_provision_sentinel_vms.sh` (VM Provisioner)
- Provisions 6 AlmaLinux 9 VMs in OrbStack (`redis-node-1` through `redis-node-6`).
- Configures official Redis RPM repositories and installs Redis 8 packages across all nodes.
- Validates internal network connectivity and IPv4 address assignment.

### 2. `02_configure_sentinel_topology.sh` (Base Sentinel Topology)
- Cleans prior state, configures `redis-node-1` as Master and links `redis-node-2` and `redis-node-3` as Replicas.
- Configures dedicated `redis-sentinel` daemons on `redis-node-4`, `redis-node-5`, and `redis-node-6` monitoring `mymaster` with Quorum = 2.

### 3. `03_configure_authenticated_sentinel.sh` (Authentication Layer)
- Deploys symmetrical password protection across data nodes (`requirepass` + `masterauth`).
- Configures Sentinels with credentials to authenticate against monitored Redis instances and peer Sentinels.

### 4. `04_configure_tls_sentinel.sh` (Production mTLS Hardening)
- Generates a private Root CA and issues SAN-backed certificates covering all 6 VM IP addresses.
- Distributes PKI certificates and private keys to `/etc/redis/tls/` across all VMs.
- Enforces TLS on ports `6379` and `26379`, sets `port 0` to disable plaintext access, and enables encrypted replication tunnels.

---

## 6. Step-by-Step Deployment Guide

### Prerequisites
- macOS host running [OrbStack](https://orbstack.dev/).
- Standard Bash terminal.

### Deployment Commands

```bash
# 1. Navigate to the sentinel repository folder
cd /Users/tufayldalvi/Documents/Important/Redis/sentinel

# 2. Grant execution permissions to all scripts
chmod +x *.sh

# 3. Stage 1: Provision 6 AlmaLinux 9 virtual machines
./01_provision_sentinel_vms.sh

# 4. Stage 2: Deploy the hardened mTLS & authenticated topology directly
./04_configure_tls_sentinel.sh
```

*(Note: Scripts `02` and `03` can be run sequentially before `04` if you want to inspect each security layer step-by-step).*

---

## 7. Operational Verification & Failover Drills

### Drill 1: Verify Plaintext Traffic Rejection
Attempt to connect to the Redis master without TLS certificates:

```bash
orb -m redis-node-1 redis-cli -p 6379 ping
```
*Expected Output:* `Connection refused` (proves the unencrypted port is closed and plaintext packets are dropped).

---

### Drill 2: Secure Authenticated Connection via mTLS
Connect using the provisioned Root CA, client certificate, client private key, and password:

```bash
orb -m redis-node-1 redis-cli \
  --tls \
  --cacert /etc/redis/tls/ca.crt \
  --cert /etc/redis/tls/redis.crt \
  --key /etc/redis/tls/redis.key \
  -a "RedisMasterPass2026!" \
  ping
```
*Expected Output:* `PONG`.

---

### Drill 3: Query Active Master from the Sentinel Layer
Ask Sentinel 1 (`redis-node-4`) for the current authoritative master:

```bash
orb -m redis-node-4 redis-cli \
  -p 26379 \
  --tls \
  --cacert /etc/redis/tls/ca.crt \
  --cert /etc/redis/tls/redis.crt \
  --key /etc/redis/tls/redis.key \
  -a "SentinelPeerPass2026!" \
  sentinel get-master-addr-by-name mymaster
```
*Expected Output:* Returns the IPv4 address of `redis-node-1` and port `6379`.

---

### Drill 4: Automated Failover Drill Under Master Crash
Simulate an abrupt master crash and observe consensus-driven failover in real time:

1. **Terminate the Redis Master daemon:**
   ```bash
   orb -m redis-node-1 sudo systemctl stop redis
   ```

2. **Inspect Sentinel event logs:**
   ```bash
   orb -m redis-node-4 sudo journalctl -u redis-sentinel -n 30 --no-pager
   ```
   *Recorded Event Sequence:*
   - `+sdown master mymaster <node-1-ip> 6379` (Node 4 detects timeout)
   - `+odown master mymaster <node-1-ip> 6379 #quorum 2/2` (Quorum reached)
   - `+try-failover master mymaster`
   - `+vote-for-leader` (Raft election)
   - `+elected-leader master mymaster`
   - `+promoted-slave slave <node-2-ip>:6379` (Replica promoted)
   - `+switch-master mymaster <node-1-ip> 6379 <node-2-ip> 6379` (Topology updated)

3. **Verify the new master:**
   ```bash
   orb -m redis-node-4 redis-cli -p 26379 --tls --cacert /etc/redis/tls/ca.crt --cert /etc/redis/tls/redis.crt --key /etc/redis/tls/redis.key -a "SentinelPeerPass2026!" sentinel get-master-addr-by-name mymaster
   ```
   *Expected Output:* Now returns the IP address of `redis-node-2` (or `node-3`).

4. **Revive `redis-node-1`:**
   ```bash
   orb -m redis-node-1 sudo systemctl start redis
   ```
   Sentinel logs show `+convert-to-slave`, and `redis-node-1` re-enters the topology cleanly as a replica of the new master.

---

## 8. Command Reference

| Task | Command |
| :--- | :--- |
| **Inspect Master Metadata** | `orb -m redis-node-4 redis-cli -p 26379 --tls --cacert /etc/redis/tls/ca.crt --cert /etc/redis/tls/redis.crt --key /etc/redis/tls/redis.key -a "SentinelPeerPass2026!" sentinel master mymaster` |
| **List Connected Replicas** | `orb -m redis-node-4 redis-cli -p 26379 --tls --cacert /etc/redis/tls/ca.crt --cert /etc/redis/tls/redis.crt --key /etc/redis/tls/redis.key -a "SentinelPeerPass2026!" sentinel replicas mymaster` |
| **List Participating Sentinels** | `orb -m redis-node-4 redis-cli -p 26379 --tls --cacert /etc/redis/tls/ca.crt --cert /etc/redis/tls/redis.crt --key /etc/redis/tls/redis.key -a "SentinelPeerPass2026!" sentinel sentinels mymaster` |
| **Inspect Data Replication** | `orb -m redis-node-1 redis-cli --tls --cacert /etc/redis/tls/ca.crt --cert /etc/redis/tls/redis.crt --key /etc/redis/tls/redis.key -a "RedisMasterPass2026!" info replication` |
| **Stream Live Sentinel Logs** | `orb -m redis-node-4 sudo journalctl -u redis-sentinel -f` |
| **Suspend All VMs** | `orb stop redis-node-{1..6}` |
| **Tear Down All VMs** | `orb delete -f redis-node-{1..6}` |
