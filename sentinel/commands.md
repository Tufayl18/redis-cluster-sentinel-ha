# Redis Sentinel: Progressive Script-by-Script Command Playbook

A progressive, script-by-script execution flow with 1-line explanations for every command, guiding you through Base Setup $\rightarrow$ Authentication $\rightarrow$ Full TLS Encryption.

---

## Script 1: VM Provisioning & Dependency Check

Run this once to verify all 6 VMs exist and have Redis installed:
```bash
./01_provision_sentinel_vms.sh
```
> **What it does:** Ensures 6 AlmaLinux 9 VMs are running, verifies Redis is installed using POSIX `command -v`, and prints the IP address of each VM.

---

## Phase 1: Base Sentinel Setup (Script 02)

### What will happen:
We set up the core High Availability topology without passwords or encryption:
- `redis-node-1`: Master (Port 6379) with split-brain safeguards (`min-replicas-to-write 1`).
- `redis-node-2` & `redis-node-3`: Replicas replicating node-1 (`replicaof`).
- `redis-node-4`, `5`, `6`: Dedicated Sentinels monitoring `mymaster` with Quorum = 2 on port 26379.

### Step 1: Run the Script
```bash
./02_configure_sentinel_topology.sh
```
> **What it does:** Cleans old cluster state (`nodes.conf`), writes standalone `redis.conf` and `sentinel.conf` with `supervised systemd`, and starts all services.

### Step 2: Verify Base Replication & Quorum
```bash
# 1. Write data on Master
orb -m redis-node-1 redis-cli set greeting "Hello from Master"
```
> **What it does:** Sets a test key on the Master node.

```bash
# 2. Read data from Replica 2
orb -m redis-node-2 redis-cli get greeting
```
> **What it does:** Confirms that Replica 2 has asynchronously synchronized the key from Master.

```bash
# 3. Check Sentinel Quorum Health
orb -m redis-node-4 redis-cli -p 26379 SENTINEL ckquorum mymaster
```
> **What it does:** Validates that at least 2 out of 3 Sentinels are alive and able to reach consensus.

```bash
# 4. Ask Sentinel for Current Master Address
orb -m redis-node-4 redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
```
> **What it does:** Queries Sentinel on port 26379 to dynamically discover the active Master's IP and port.

### Step 3: Base Failover Test
```bash
# Kill Master node-1
orb -m redis-node-1 -u root systemctl stop redis

# Wait 7 seconds, then ask Sentinel who became the new Master
orb -m redis-node-4 redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# Bring old Master back online (auto-demoted to replica)
orb -m redis-node-1 -u root systemctl start redis
```
> **What it does:** Simulates master crash, observes Sentinel promote a replica to master, and watches old master recover as a replica.

---

## Phase 2: Secure Symmetrical Authentication (Script 03)

### What will happen:
In Sentinel, any replica can become a Master, and any Master can become a Replica. Therefore:
- All data nodes must have identical `requirepass` AND `masterauth` (`RedisMasterPass2026!`).
- Sentinels must have `sentinel auth-pass mymaster` so they can issue commands to data nodes.
- Sentinels must protect their own port 26379 with `requirepass` and `sentinel sentinel-pass` (`SentinelPeerPass2026!`).
- Protected mode is safely turned on (`protected-mode yes`).

### Step 1: Run the Script
```bash
./03_configure_authenticated_sentinel.sh
```
> **What it does:** Re-configures all nodes with symmetrical passwords, enforces `protected-mode yes`, and restarts all services.

### Step 2: Verify Authentication Enforcement
```bash
# 1. Test unauthenticated request on Master (Must FAIL)
orb -m redis-node-1 redis-cli ping
```
> **What it does:** Confirms Redis blocks unauthenticated access with `(error) NOAUTH Authentication required.`

```bash
# 2. Test authenticated request on Master (Must SUCCEED)
orb -m redis-node-1 redis-cli -a 'RedisMasterPass2026!' ping
```
> **What it does:** Authenticates using `-a` and receives `PONG`.

```bash
# 3. Test unauthenticated request on Sentinel (Must FAIL)
orb -m redis-node-4 redis-cli -p 26379 ping
```
> **What it does:** Confirms Sentinel port 26379 blocks unauthenticated access with `(error) NOAUTH`.

```bash
# 4. Test authenticated request on Sentinel (Must SUCCEED)
orb -m redis-node-4 redis-cli -p 26379 -a 'SentinelPeerPass2026!' ping
```
> **What it does:** Authenticates to Sentinel using `-a` and receives `PONG`.

```bash
# 5. Check Sentinel Quorum under Authentication
orb -m redis-node-4 redis-cli -p 26379 -a 'SentinelPeerPass2026!' SENTINEL ckquorum mymaster
```
> **What it does:** Verifies all 3 Sentinels are communicating and authorized under password protection.

### Step 3: Failover Test under Authentication
```bash
# 1. Kill current Master (node-1)
orb -m redis-node-1 -u root systemctl stop redis

# 2. Wait 7 seconds, then query Sentinel for new Master using auth
orb -m redis-node-4 redis-cli -p 26379 -a 'SentinelPeerPass2026!' SENTINEL get-master-addr-by-name mymaster

# 3. Write data to promoted node (e.g. node-2) with password
orb -m redis-node-2 redis-cli -a 'RedisMasterPass2026!' set auth_key "Auth verified"

# 4. Revive old master (node-1)
orb -m redis-node-1 -u root systemctl start redis

# 5. Verify old master re-joined as replica and replicated the key
orb -m redis-node-1 redis-cli -a 'RedisMasterPass2026!' get auth_key
```
> **What it does:** Proves that Sentinel can promote replicas and replicas can re-authenticate to the new master without human intervention.

---

## Phase 3: Full TLS Encryption for Data-in-Transit (Script 04)

### What will happen:
Passwords prevent unauthorized commands, but traffic is still sent in plaintext over the network. Script 04 secures all data-in-transit:
- Generates a private Certificate Authority (CA) root (`ca.crt`).
- Generates Server and Client certificates with Subject Alternative Names (SAN) for all 6 VM IPs and hostnames.
- Disables insecure plaintext TCP (`port 0`).
- Enables TLS on Redis data port (`tls-port 6379`) and Sentinel port (`tls-port 26379`).
- Encrypts master-replica replication and Sentinel gossip streams (`tls-replication yes`).

### Step 1: Run the Script
```bash
./04_configure_tls_sentinel.sh
```
> **What it does:** Creates PKI certificates, distributes them to `/etc/redis/tls/` on all 6 VMs, disables plaintext `port 0`, enables TLS, and restarts all services.

### Step 2: Verify TLS Enforcement & Encrypted Connectivity
```bash
# 1. Test Plaintext TCP (Must FAIL)
orb -m redis-node-1 redis-cli -p 6379 ping
```
> **What it does:** Confirms insecure plaintext connections are completely blocked since `port 0` is disabled.

```bash
# 2. Test Encrypted Redis Connection (mTLS + Password)
orb -m redis-node-1 redis-cli --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key --cacert /etc/redis/tls/ca.crt -a 'RedisMasterPass2026!' ping
```
> **What it does:** Connects via mutual TLS using client certificates and password, receiving `PONG`.

```bash
# 3. Test Encrypted Sentinel Quorum (mTLS + Password)
orb -m redis-node-4 redis-cli -p 26379 --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key --cacert /etc/redis/tls/ca.crt -a 'SentinelPeerPass2026!' SENTINEL ckquorum mymaster
```
> **What it does:** Verifies that Sentinel quorum gossip is healthy and fully encrypted over port 26379.

```bash
# 4. Discover Master Address over TLS
orb -m redis-node-4 redis-cli -p 26379 --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key --cacert /etc/redis/tls/ca.crt -a 'SentinelPeerPass2026!' SENTINEL get-master-addr-by-name mymaster
```
> **What it does:** Asks Sentinel over an encrypted TLS channel to report the active Master IP and port.

### Step 3: Final Production Failover Drill (TLS + Auth)
```bash
# 1. Stop active Master
orb -m redis-node-1 -u root systemctl stop redis

# 2. Query Sentinel for promoted Master over TLS
orb -m redis-node-4 redis-cli -p 26379 --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key --cacert /etc/redis/tls/ca.crt -a 'SentinelPeerPass2026!' SENTINEL get-master-addr-by-name mymaster

# 3. Write data to newly promoted Master over TLS
orb -m redis-node-2 redis-cli --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key --cacert /etc/redis/tls/ca.crt -a 'RedisMasterPass2026!' set prod_test "Production TLS Verified"

# 4. Read from other replica over TLS
orb -m redis-node-3 redis-cli --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key --cacert /etc/redis/tls/ca.crt -a 'RedisMasterPass2026!' get prod_test

# 5. Revive old Master
orb -m redis-node-1 -u root systemctl start redis

# 6. Verify old Master re-joined as replica and replicated data over TLS
orb -m redis-node-1 redis-cli --tls --cert /etc/redis/tls/client.crt --key /etc/redis/tls/client.key --cacert /etc/redis/tls/ca.crt -a 'RedisMasterPass2026!' get prod_test
```
> **What it does:** Proves end-to-end production readiness: failure detection, leader election, replica promotion, client write recovery, and automatic node rejoin all executed over fully encrypted, authenticated channels.
