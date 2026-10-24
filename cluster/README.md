# Redis Cluster: Architecture, Sharding & Operations Guide

> **Topology:** 6 Nodes (3 Masters + 3 Replicas)  
> **Environment:** AlmaLinux 9 Virtual Machines on OrbStack  
> **Engine:** Redis v8.x (64-bit)  
> **Clustering:** 16,384 Hash Slots, Cluster Bus Gossip Protocol (`16379`)

---

## Table of Contents
1. [Project Overview (In Simple Terms)](#1-project-overview-in-simple-terms)
   - [What is Redis?](#what-is-redis)
   - [The Problem with a Single Redis Server](#the-problem-with-a-single-redis-server)
   - [What is Redis Cluster and Why Do We Need It?](#what-is-redis-cluster-and-why-do-we-need-it)
2. [Technical Deep Dive: How Redis Cluster Works](#2-technical-deep-dive-how-redis-cluster-works)
   - [Data Sharding via 16,384 Hash Slots](#data-sharding-via-16384-hash-slots)
   - [Cluster Bus & Gossip Protocol (`16379`)](#cluster-bus--gossip-protocol-16379)
   - [Failure Detection & Automatic Failover Mechanics](#failure-detection--automatic-failover-mechanics)
   - [Client Routing & Redirection (MOVED vs. ASK)](#client-routing--redirection-moved-vs-ask)
3. [Lab Architecture & Node Allocation Map](#3-lab-architecture--node-allocation-map)
4. [Automation Scripts Breakdown](#4-automation-scripts-breakdown)
5. [Step-by-Step Deployment Guide](#5-step-by-step-deployment-guide)
6. [Operational Verification & Failover Drills](#6-operational-verification--failover-drills)
7. [Command Reference](#7-command-reference)

---

## 1. Project Overview (In Simple Terms)

### What is Redis?
Redis (Remote Dictionary Server) is an ultra-fast, in-memory data store. 
Unlike traditional databases (like MySQL or PostgreSQL) that store data on physical disks (HDDs or SSDs), Redis stores all data directly in the computer's **RAM (Random Access Memory)**. Because RAM operates in nanoseconds rather than the milliseconds required for disk input/output, Redis delivers sub-millisecond response times and handles hundreds of thousands of operations per second.

### The Problem with a Single Redis Server
Running a single Redis server in a production system introduces three major bottlenecks:
1. **Memory Capacity Limits:** RAM is finite. If your single server has 32 GB of RAM, your dataset can never exceed 32 GB. You cannot store 100 GB or 1 TB of cache in memory on that machine.
2. **Single Point of Failure (SPOF):** If that single server crashes, experiences a hardware failure, or undergoes a reboot, your application immediately loses access to its database and cache. All operations stop.
3. **CPU Throughput Ceiling:** Redis executes commands using a core single-threaded event loop. A single Redis instance can only utilize one CPU core, capping maximum write throughput.

### What is Redis Cluster and Why Do We Need It?
**Redis Cluster** is a distributed implementation of Redis that combines multiple servers into one unified system to solve the limitations of a single instance:
- **Horizontal Scaling (Data Sharding):** Instead of keeping all data on one machine, Redis Cluster splits the data evenly across multiple master servers. If you have 3 masters with 32 GB of RAM each, you now have 96 GB of total memory capacity and 3 CPU cores processing operations in parallel.
- **High Availability (Automatic Failover):** Every master server has a dedicated backup copy called a **replica**. If any master server crashes, its replica automatically detects the failure and promotes itself to become the new master in under 2 seconds—without human intervention or application downtime.

---

## 2. Technical Deep Dive: How Redis Cluster Works

```
                     Client Application (Cluster-Aware Driver)
                                       |
                 +---------------------+---------------------+
                 |                     |                     |
          (Slots 0 - 5460)     (Slots 5461 - 10922)  (Slots 10923 - 16383)
                 v                     v                     v
          +--------------+      +--------------+      +--------------+
          |   Master 1   |      |   Master 2   |      |   Master 3   |  Port 6379 (Client Traffic)
          | redis-node-1 |      | redis-node-2 |      | redis-node-3 |
          +--------------+      +--------------+      +--------------+
                 ^                     ^                     ^
                 | (Gossip Bus)        | (Gossip Bus)        | (Gossip Bus) Port 16379 (Node Mesh)
                 v                     v                     v
          +--------------+      +--------------+      +--------------+
          |  Replica 1   |      |  Replica 2   |      |  Replica 3   |  Port 6379 (Replication Sync)
          | redis-node-5 |      | redis-node-6 |      | redis-node-4 |
          +--------------+      +--------------+      +--------------+
```

### Data Sharding via 16,384 Hash Slots
Redis Cluster does not use consistent hashing. Instead, it introduces the concept of **Hash Slots**:
- The entire keyspace is divided into exactly **16,384 discrete slots** (numbered `0` through `16383`).
- When a client issues a command (such as `SET user:100 "active"`), Redis determines which slot owns the key using the **CRC16** algorithm modulo 16,384:
  $$\text{Slot} = \text{CRC16}(\text{key}) \pmod{16384}$$
- The 16,384 slots are divided equally across the master nodes:
  - **Master 1 (`redis-node-1`):** Serves slots `0` to `5460` (5,461 slots).
  - **Master 2 (`redis-node-2`):** Serves slots `5461` to `10922` (5,462 slots).
  - **Master 3 (`redis-node-3`):** Serves slots `10923` to `16383` (5,461 slots).
- **Hash Tags:** To ensure multi-key operations (like transactions or `MGET`) execute on the same node, Redis supports hash tags `{...}`. Only the string inside `{}` is hashed (e.g., `{user:100}:profile` and `{user:100}:orders` hash to the exact same slot).

### Cluster Bus & Gossip Protocol (`16379`)
Unlike systems that rely on external coordinators (like Apache ZooKeeper or Consul), Redis Cluster uses a fully decentralized peer-to-peer mesh:
- Every node opens a secondary communication port at base port `+ 10000` (port `16379`), called the **Cluster Bus**.
- Nodes continuously exchange binary `PING` and `PONG` packets over the Cluster Bus using a **Gossip Protocol**.
- In every exchange, nodes share state about themselves and a random sample of other cluster nodes, continuously propagating cluster topology, node health, and slot ownership changes.

### Failure Detection & Automatic Failover Mechanics
1. **PFAIL (Possible Failure):** If Node A sends a heartbeat `PING` to Node B and receives no response within `cluster-node-timeout` (configured at `5000ms`), Node A marks Node B as `PFAIL`.
2. **FAIL (Confirmed Failure):** Node A communicates Node B's `PFAIL` state to other nodes via gossip. When a majority of master nodes confirm Node B is unreachable, Node B is marked as `FAIL`.
3. **Replica Election:** The replica paired with the failed master initiates failover. It increments the cluster configuration epoch and broadcasts a `FAILOVER_AUTH_REQUEST` to all surviving masters.
4. **Majority Vote & Promotion:** Each master can grant one vote per epoch. Once the replica secures a majority vote, it promotes itself to `master`, claims the failed master's hash slots, and broadcasts a heartbeat to update all node routing tables.

### Client Routing & Redirection (MOVED vs. ASK)
- Standard Redis clients connect to any node. If the requested key belongs to a slot managed by that node, the query executes immediately.
- If the key belongs to a slot on another node, the current node replies with a `-MOVED <slot> <target-ip>:<target-port>` error.
- Cluster-aware client libraries automatically intercept `-MOVED`, update their internal routing table cache, and transparently re-route the query to the correct master.

---

## 3. Lab Architecture & Node Allocation Map

The lab is provisioned across 6 isolated AlmaLinux 9 Virtual Machines on OrbStack:

| VM Host | Role | Client Port | Cluster Bus | Assigned Hash Slots | Paired Node |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`redis-node-1`** | **Master 1** | `6379` | `16379` | `0` – `5460` (5,461 slots) | `redis-node-5` (Replica) |
| **`redis-node-2`** | **Master 2** | `6379` | `16379` | `5461` – `10922` (5,462 slots) | `redis-node-6` (Replica) |
| **`redis-node-3`** | **Master 3** | `6379` | `16379` | `10923` – `16383` (5,461 slots) | `redis-node-4` (Replica) |
| **`redis-node-4`** | **Replica 3** | `6379` | `16379` | Secondary / Hot Standby | Master 3 (`redis-node-3`) |
| **`redis-node-5`** | **Replica 1** | `6379` | `16379` | Secondary / Hot Standby | Master 1 (`redis-node-1`) |
| **`redis-node-6`** | **Replica 2** | `6379` | `16379` | Secondary / Hot Standby | Master 2 (`redis-node-2`) |

---

## 4. Automation Scripts Breakdown

The repository provides 3 modular Bash automation scripts to stand up and manage the cluster:

### 1. `01_provision_vms.sh` (VM Provisioning & Engine Installation)
- Queries OrbStack to verify if `redis-node-1` through `redis-node-6` exist. Missing VMs are created using AlmaLinux 9 with dedicated RAM allocations.
- Configures the official Redis RPM repository and imports GPG keys on each machine.
- Installs the Redis server binary (`redis v8.x`) and verifies network reachability between all VMs.

### 2. `02_configure_cluster_nodes.sh` (State Sanitization & Cluster Configuration)
- Stops any previously active Redis or Sentinel processes.
- Wipes stale state files (`nodes.conf`, `dump.rdb`, `appendonlydir/`) to ensure deterministic initialization.
- Deploys a production `redis.conf` with:
  - `cluster-enabled yes`
  - `cluster-config-file nodes.conf`
  - `cluster-node-timeout 5000`
  - `appendonly yes` (`appendfsync everysec`)
  - `maxmemory 256mb` (`allkeys-lru` eviction policy)
- Restarts and enables `redis.service` across all 6 machines.

### 3. `03_cluster_creation.sh` (Cluster Initialization & Slot Allocation)
- Dynamically discovers the private IPv4 addresses of all 6 VMs.
- Runs `redis-cli --cluster create` to distribute all 16,384 hash slots across 3 masters and configures 3 secondary replicas (`--cluster-replicas 1`).
- Validates cluster convergence and outputs the resulting node and slot layout.

---

## 5. Step-by-Step Deployment Guide

### Prerequisites
- macOS host running [OrbStack](https://orbstack.dev/).
- Standard Bash terminal.

### Deployment Commands

```bash
# 1. Navigate to the cluster repository folder
cd /Users/tufayldalvi/Documents/Important/Redis/cluster

# 2. Grant execution permissions to all scripts
chmod +x 01_provision_vms.sh 02_configure_cluster_nodes.sh 03_cluster_creation.sh

# 3. Stage 1: Provision 6 AlmaLinux 9 virtual machines
./01_provision_vms.sh

# 4. Stage 2: Deploy cluster configuration to all nodes
./02_configure_cluster_nodes.sh

# 5. Stage 3: Form the cluster and allocate hash slots
./03_cluster_creation.sh
```

---

## 6. Operational Verification & Failover Drills

### Drill 1: Verify Cluster Health & Topology
Check that all 16,384 slots are assigned and the cluster state is operational:

```bash
orb -m redis-node-1 redis-cli cluster info
orb -m redis-node-1 redis-cli cluster nodes
```
*Expected Output:* `cluster_state: ok`, `cluster_slots_ok: 16384`, `cluster_size: 3`.

---

### Drill 2: Test Cluster Routing & Automatic Redirection
Connect using the cluster-aware flag (`-c`):

```bash
orb -m redis-node-1 redis-cli -c
```

Set keys and observe how Redis calculates the slot and automatically redirects your client to the correct master:
```text
127.0.0.1:6379> SET user:session:101 "Authorized"
-> Redirected to slot [8942] located at 192.168.215.3:6379
OK

192.168.215.3:6379> SET inventory:product:55 "InStock"
-> Redirected to slot [14125] located at 192.168.215.4:6379
OK
```

---

### Drill 3: Automated Failover Under Master Failure
Simulate a sudden crash of Master 1 (`redis-node-1`) and watch its replica take over:

1. **Stop the Redis service on Master 1:**
   ```bash
   orb -m redis-node-1 sudo systemctl stop redis
   ```

2. **Inspect the cluster from an alternate node:**
   ```bash
   orb -m redis-node-2 redis-cli cluster nodes
   ```
   *Observations:*
   - `redis-node-1` is flagged as `fail`.
   - `redis-node-5` (Replica 1) is automatically promoted from `slave` to `master` and assumes ownership of slots `0-5460`.
   - Total failover time is typically under 2 seconds; cluster state remains `ok`.

3. **Restore `redis-node-1`:**
   ```bash
   orb -m redis-node-1 sudo systemctl start redis
   ```
   *Observations:* `redis-node-1` rejoins the cluster, reads the updated epoch from `nodes.conf`, and reconfigures itself as a replica of the new master (`redis-node-5`).

---

## 7. Command Reference

| Task | Command |
| :--- | :--- |
| **Cluster Health Summary** | `orb -m redis-node-1 redis-cli cluster info` |
| **Inspect Node & Slot Map** | `orb -m redis-node-1 redis-cli cluster nodes` |
| **Interactive Cluster CLI** | `orb -m redis-node-1 redis-cli -c` |
| **Compute Hash Slot of Key**| `orb -m redis-node-1 redis-cli cluster keyslot "<key_name>"` |
| **Validate Cluster Health** | `orb -m redis-node-1 redis-cli --cluster check 127.0.0.1:6379` |
| **Suspend All VMs** | `orb stop redis-node-{1..6}` |
| **Tear Down All VMs** | `orb delete -f redis-node-{1..6}` |
