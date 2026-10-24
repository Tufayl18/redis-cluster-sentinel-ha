#!/usr/bin/env bash
# ==============================================================================
# Script: 03_configure_authenticated_sentinel.sh
# Purpose: Configure 6 VMs into Authenticated Redis Sentinel Topology:
#   - redis-node-1: Master (Port 6379) with requirepass + masterauth
#   - redis-node-2: Replica 1 (Port 6379) with requirepass + masterauth
#   - redis-node-3: Replica 2 (Port 6379) with requirepass + masterauth
#   - redis-node-4: Dedicated Sentinel 1 (Port 26379) with sentinel auth-pass + sentinel-pass
#   - redis-node-5: Dedicated Sentinel 2 (Port 26379) with sentinel auth-pass + sentinel-pass
#   - redis-node-6: Dedicated Sentinel 3 (Port 26379) with sentinel auth-pass + sentinel-pass
# Passwords:
#   - Redis Data Layer: "RedisMasterPass2026!"
#   - Sentinel Consensus Layer: "SentinelPeerPass2026!"
# ==============================================================================

set -euo pipefail

REDIS_PASS="RedisMasterPass2026!"
SENTINEL_PASS="SentinelPeerPass2026!"

echo "=================================================="
echo "Stage 0: Ensuring all 6 VMs are Running"
echo "=================================================="

for i in {1..6}; do
    NAME="redis-node-${i}"
    echo "Starting ${NAME} (if not already running)..."
    orb start "${NAME}" || true
done

echo "=================================================="
echo "Stage 1: Fetching Dynamic IP of Master (redis-node-1)"
echo "=================================================="

MASTER_IP=$(orb -m redis-node-1 ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)

if [[ -z "${MASTER_IP}" || "${MASTER_IP}" == "127.0.0.1" ]]; then
    echo "ERROR: Could not resolve valid network IP for redis-node-1 (got: '${MASTER_IP}'). Aborting."
    exit 1
fi

echo "Master (redis-node-1) IP: ${MASTER_IP}"

echo "=================================================="
echo "Stage 2: Stopping Services & Clearing Cluster State"
echo "=================================================="

for i in {1..6}; do
    NAME="redis-node-${i}"
    echo "--> Cleaning state on ${NAME}..."
    orb -m "${NAME}" -u root bash -c '
        systemctl stop redis 2>/dev/null || true
        systemctl stop redis-sentinel 2>/dev/null || true
        systemctl reset-failed redis 2>/dev/null || true
        systemctl reset-failed redis-sentinel 2>/dev/null || true
        rm -f /var/lib/redis/nodes.conf*
        rm -f /var/lib/redis/dump.rdb*
        rm -rf /var/lib/redis/appendonlydir*
        mkdir -p /var/lib/redis
        chown -R redis:redis /var/lib/redis
    '
done

echo "=================================================="
echo "Stage 3: Configuring Authenticated Data Layer (Nodes 1, 2, 3)"
echo "=================================================="

# 1. Configure Master (redis-node-1)
echo "--> Configuring Master (redis-node-1) with requirepass & masterauth..."
orb -m redis-node-1 -u root bash -c "cat << EOF > /etc/redis/redis.conf
port 6379
bind 0.0.0.0
protected-mode yes
daemonize no
supervised systemd
dir /var/lib/redis

# Cluster Disabled
cluster-enabled no

# Memory Management
maxmemory 256mb
maxmemory-policy allkeys-lru

# Persistence
appendonly yes
appendfilename \"appendonly.aof\"
appendfsync everysec

# Split-Brain Safeguards
min-replicas-to-write 1
min-replicas-max-lag 10

# Authentication (Symmetrical for Failover Support)
requirepass ${REDIS_PASS}
masterauth ${REDIS_PASS}
EOF
chown -R redis:redis /etc/redis /var/lib/redis
"

# 2. Configure Replicas (redis-node-2 and redis-node-3)
for i in 2 3; do
    NAME="redis-node-${i}"
    echo "--> Configuring Replica (${NAME}) with requirepass & masterauth..."
    orb -m "${NAME}" -u root bash -c "cat << EOF > /etc/redis/redis.conf
port 6379
bind 0.0.0.0
protected-mode yes
daemonize no
supervised systemd
dir /var/lib/redis

# Cluster Disabled
cluster-enabled no

# Memory Management
maxmemory 256mb
maxmemory-policy allkeys-lru

# Persistence
appendonly yes
appendfilename \"appendonly.aof\"
appendfsync everysec

# Split-Brain Safeguards
min-replicas-to-write 1
min-replicas-max-lag 10

# Authentication (Symmetrical for Failover Support)
requirepass ${REDIS_PASS}
masterauth ${REDIS_PASS}

# Point to Master
replicaof ${MASTER_IP} 6379
EOF
chown -R redis:redis /etc/redis /var/lib/redis
"
done

echo "=================================================="
echo "Stage 4: Configuring Authenticated Sentinel Quorum (Nodes 4, 5, 6)"
echo "=================================================="

for i in 4 5 6; do
    NAME="redis-node-${i}"
    echo "--> Configuring Sentinel (${NAME}) with auth-pass & sentinel-pass..."
    orb -m "${NAME}" -u root bash -c "
mkdir -p /etc/redis/sentinel
cat << EOF > /etc/redis/sentinel/sentinel.conf
port 26379
bind 0.0.0.0
protected-mode yes
daemonize no
supervised systemd
dir /tmp

# Monitoring Master: sentinel monitor <master-name> <ip> <port> <quorum>
sentinel monitor mymaster ${MASTER_IP} 6379 2

# Authenticating to Redis Data Nodes
sentinel auth-pass mymaster ${REDIS_PASS}

# Securing Sentinel Daemon Port (26379)
requirepass ${SENTINEL_PASS}
sentinel sentinel-pass ${SENTINEL_PASS}

# Failure Detection Timing
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel parallel-syncs mymaster 1
EOF
chown -R redis:redis /etc/redis
chmod 644 /etc/redis/sentinel/sentinel.conf
"
done

echo "=================================================="
echo "Stage 5: Starting Services"
echo "=================================================="

echo "--> Starting/Restarting Redis Data Nodes (1, 2, 3)..."
for i in 1 2 3; do
    orb -m "redis-node-${i}" -u root systemctl restart redis
done

echo "--> Starting/Restarting Sentinel Daemons (4, 5, 6)..."
for i in 4 5 6; do
    orb -m "redis-node-${i}" -u root systemctl restart redis-sentinel
done

echo "=================================================="
echo "Authenticated Sentinel Setup Complete!"
echo "Master IP: ${MASTER_IP}"
echo "Redis Password: ${REDIS_PASS}"
echo "Sentinel Password: ${SENTINEL_PASS}"
echo "=================================================="
