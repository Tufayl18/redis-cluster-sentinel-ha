# Production Redis Infrastructure: High Availability & Distributed Clustering

[![Redis](https://img.shields.io/badge/Redis-v8.x-red.svg)](https://redis.io)
[![OS](https://img.shields.io/badge/OS-AlmaLinux%209-blue.svg)](https://almalinux.org)
[![Security](https://img.shields.io/badge/Security-mTLS%20%2B%20Auth-green.svg)](#security-profile)
[![Topology](https://img.shields.io/badge/Topology-6%20VM%20Mesh-orange.svg)](#topologies-at-a-glance)

A comprehensive, production-grade engineering lab implementing the two core distributed high-availability architectures for Redis across 6 isolated Linux Virtual Machines (AlmaLinux 9 on OrbStack):

1. **Redis Cluster Mode:** Horizontal write scaling, automated data sharding across 16,384 hash slots, and decentralized gossip bus recovery.
2. **Redis Sentinel Mode:** High availability for a single-master dataset with quorum-based leader election, dual-layer authentication, and strict Mutual TLS (mTLS) encryption.

---

## 📑 Repository Structure

```text
.
├── README.md                                  # Root architectural overview & quickstart
├── stop_machines.sh                           # Graceful VM suspension script
│
├── cluster/                                   # Redis Cluster Architecture (3M + 3R)
│   ├── 01_provision_vms.sh                    # VM provisioning & Redis 8 installation
│   ├── 02_configure_cluster_nodes.sh          # Node configuration & state sanitization
│   ├── 03_cluster_creation.sh                 # 16,384 slot allocation & cluster mesh
│   ├── commands.md                            # Cluster CLI cheat sheet
│   └── README.md                              # In-depth Cluster technical guide
│
└── sentinel/                                  # Redis Sentinel Architecture (1M + 2R + 3S)
    ├── 01_provision_sentinel_vms.sh           # VM provisioning & Redis 8 installation
    ├── 02_configure_sentinel_topology.sh      # Base Master-Replica + Sentinel quorum
    ├── 03_configure_authenticated_sentinel.sh # Dual-layer password authentication
    ├── 04_configure_tls_sentinel.sh           # Full mTLS encryption (CA, SAN certs, port 0)
    ├── commands.md                            # Sentinel CLI cheat sheet
    └── README.md                              # In-depth Sentinel technical guide
```

---

## ⚖️ Topologies at a Glance

| Feature | [Redis Cluster Mode](./cluster/README.md) | [Redis Sentinel Mode](./sentinel/README.md) |
| :--- | :--- | :--- |
| **Primary Architectural Goal** | Horizontal write scaling & dataset sharding | High Availability & automated failover |
| **Data Partitioning** | **16,384 Hash Slots** distributed across 3 masters | **None**; full dataset replicated across all replicas |
| **Service Ports** | `6379` (Data) + `16379` (Cluster Bus) | `6379` (Data) + `26379` (Sentinel Daemon) |
| **Coordinator / Consensus** | Decentralized gossip mesh & epoch voting | Independent external Sentinel quorum (Quorum: 2/3) |
| **Node Layout (6 VMs)** | 3 Masters + 3 Replicas | 1 Master + 2 Replicas + 3 Dedicated Sentinels |
| **Security Layer** | Multi-node firewall & node isolation | **Mutual TLS (mTLS)** with private CA + dual passwords |
| **Client Requirement** | Cluster-aware client (handles `-MOVED` redirects) | Sentinel-aware client (queries Sentinel for active master) |

---

## 🚀 Quickstart Guides

### Option A: Launching Redis Cluster (Horizontal Sharding)

Redis Cluster partitions data across 3 master nodes and pairs each master with a dedicated hot standby replica.

```bash
# 1. Enter the cluster directory
cd cluster

# 2. Grant script execution permissions
chmod +x *.sh

# 3. Provision 6 AlmaLinux 9 VMs and install Redis
./01_provision_vms.sh

# 4. Configure cluster settings and clean state
./02_configure_cluster_nodes.sh

# 5. Form cluster and assign 16,384 hash slots
./03_cluster_creation.sh
```
👉 *Read the full [Cluster Technical Guide & Failover Playbook](./cluster/README.md).*

---

### Option B: Launching Redis Sentinel (High Availability + mTLS)

Redis Sentinel operates 3 external watchdogs over a single master and 2 replicas, hardened with private Root CA certificates, SAN-backed client/server certs, and disabled plaintext ports.

```bash
# 1. Enter the sentinel directory
cd sentinel

# 2. Grant script execution permissions
chmod +x *.sh

# 3. Provision 6 AlmaLinux 9 VMs and install Redis
./01_provision_sentinel_vms.sh

# 4. Deploy production mTLS encryption and authenticated quorum
./04_configure_tls_sentinel.sh
```
👉 *Read the full [Sentinel Technical Guide & Failover Playbook](./sentinel/README.md).*

---

## 🔄 Seamless Topology Switching (Zero Manual Cleanup)

Both architectures share the same 6 virtual machines (`redis-node-1` through `redis-node-6`). 

You **do not need manual cleanup steps or separate switching files** because the configuration scripts are **100% idempotent and self-cleaning**:
- **To switch to Cluster Mode:** Simply run `cluster/02_configure_cluster_nodes.sh` followed by `03_cluster_creation.sh`. Script 02 automatically stops any active Sentinel processes, wipes `sentinel.conf`, purges stale datasets, and initializes the cluster bus.
- **To switch to Sentinel Mode:** Simply run `sentinel/02_configure_sentinel_topology.sh` (or `04_configure_tls_sentinel.sh`). Script 02 automatically stops cluster daemons, wipes `nodes.conf`, disables clustering (`cluster-enabled no`), and deploys the Master-Replica-Sentinel hierarchy.

---

## 🛠️ Infrastructure & VM Management

To pause all 6 virtual machines to save host battery and memory:
```bash
./stop_machines.sh
```

To delete and wipe all 6 virtual machines completely:
```bash
orb delete -f redis-node-{1..6}
```
