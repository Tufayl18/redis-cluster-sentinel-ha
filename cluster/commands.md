# Redis Cluster: Complete Execution Flow & Command Playbook

A step-by-step operational guide with 1-line explanations for every action, from provisioning to live failover testing.

---

## 1. End-to-End Execution Flow

### Step 1: Provision VMs & Install Redis Engine
```bash
./01_provision_vms.sh
```
> **What it does:** Ensures 6 AlmaLinux 9 VMs exist on OrbStack, installs Redis 8.10 via official RPM repository, and verifies network IPs.

---

### Step 2: Clean Old State & Configure Cluster Nodes
```bash
./02_configure_cluster_nodes.sh
```
> **What it does:** Stops any old Sentinel services, wipes stale cluster metadata (`nodes.conf`), sets `cluster-enabled yes` on all 6 VMs, enables AOF persistence, and starts Redis.

---

### Step 3: Form the 16,384 Hash Slot Cluster (3 Masters + 3 Replicas)
```bash
./03_cluster_creation.sh
```
> **What it does:** Collects all 6 VM IPs and runs `redis-cli --cluster create` with `--cluster-replicas 1` to assign slots 0–16383 to 3 masters and pair 3 replicas.

---

## 2. Operational Verification Commands

### 1. Check Overall Cluster Health & State
```bash
orb -m redis-node-1 redis-cli cluster info
```
> **What it does:** Confirms `cluster_state:ok`, `cluster_slots_assigned:16384`, and `cluster_known_nodes:6`.

---

### 2. View Node Topology, Roles & Slot Allocations
```bash
orb -m redis-node-1 redis-cli cluster nodes
```
> **What it does:** Displays all 6 nodes, their unique Node IDs, IP addresses, Master/Replica pairings, and assigned slot ranges (e.g., `0-5460`).

---

### 3. Write Data with Smart Cluster Routing (`-c` flag)
```bash
orb -m redis-node-1 redis-cli -c set mykey "Hello Cluster"
```
> **What it does:** The `-c` (cluster mode) flag allows the CLI to follow `-MOVED` redirects automatically, routing the write to whichever master owns the calculated hash slot.

---

### 4. Observe Raw `-MOVED` Redirection (Without `-c` flag)
```bash
orb -m redis-node-1 redis-cli set key_on_other_node "value"
```
> **What it does:** Demonstrates how raw Redis Cluster works—if the slot belongs to another master, Redis rejects the query with `(error) MOVED <slot> <target_ip>:6379`.

---

### 5. Multi-Key Operations Using Hash Tags (`{...}`)
```bash
orb -m redis-node-1 redis-cli -c mset {account:50}:name "Alice" {account:50}:balance "5000"
```
> **What it does:** Uses `{account:50}` hash tag to force both keys to hash to the identical slot, enabling atomic multi-key commands without cross-slot errors.

---

### 6. Read From Replicas Using `READONLY` Socket Hopping
```bash
orb -m redis-node-4 redis-cli
```
Inside the interactive prompt:
```text
READONLY
GET mykey
```
> **What it does:** By default replicas reject read queries; issuing `READONLY` unlocks the connection to serve read queries directly from replica memory.

---

## 3. High Availability & Failover Simulation

### 1. Check which master owns slot ranges:
```bash
orb -m redis-node-1 redis-cli cluster nodes | grep master
```
> **What it does:** Identifies the active master VMs and their associated slot ranges.

---

### 2. Simulate Master Failure (Crash Master 2):
```bash
orb -m redis-node-2 -u root systemctl stop redis
```
> **What it does:** Stops the Redis daemon on Master 2 to trigger cluster failure detection.

---

### 3. Watch Live Election & Promotion via Cluster Nodes:
```bash
orb -m redis-node-1 redis-cli cluster nodes
```
> **What it does:** Within 5 seconds, peer nodes mark Master 2 as `fail`, and its assigned replica automatically promotes itself to become the new Master for those slots.

---

### 4. Verify Reads & Writes Continue Without Interruption:
```bash
orb -m redis-node-1 redis-cli -c get mykey
```
> **What it does:** Proves that the remaining masters continue serving client traffic seamlessly.

---

### 5. Recover the Failed Node:
```bash
orb -m redis-node-2 -u root systemctl start redis
```
> **What it does:** Starts the old master back up; it connects to the cluster bus and automatically re-joins as a **replica** of the newly promoted master!
