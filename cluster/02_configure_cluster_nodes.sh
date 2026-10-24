#!/usr/bin/env bash
# ==============================================================================
# Script: 02_configure_cluster_nodes.sh (Cluster Lab)
# Purpose: Configure 6 VMs into Redis Cluster Mode:
#   - Stops and disables any running Sentinel services
#   - Clears any old Sentinel or Cluster state files
#   - Deploys clean, dedicated Cluster configuration
#   - Enables cluster-enabled yes on all 6 nodes
# Supports clean, automated switching from Sentinel mode!
# ==============================================================================

set -euo pipefail

echo "=================================================="
echo "Stage 0: Ensuring all 6 VMs are Running"
echo "=================================================="

for i in {1..6}; do
    NAME="redis-node-${i}"
    echo "Starting ${NAME} (if not already running)..."
    orb start "${NAME}" || true
done

echo "=================================================="
echo "Stage 1: Stopping Sentinel/Old Services & Purging State"
echo "=================================================="

for i in {1..6}; do
    NAME="redis-node-${i}"
    echo "--> Cleaning state on ${NAME}..."
    orb -m "${NAME}" -u root bash -c '
        # Stop both services
        systemctl stop redis-sentinel 2>/dev/null || true
        systemctl disable redis-sentinel 2>/dev/null || true
        systemctl stop redis 2>/dev/null || true

        # Reset any failed systemd counters
        systemctl reset-failed redis 2>/dev/null || true
        systemctl reset-failed redis-sentinel 2>/dev/null || true

        # Wipe old Sentinel configuration files
        rm -rf /etc/redis/sentinel*
        rm -f /etc/redis-sentinel.conf*

        # Wipe old cluster metadata, slot assignments, and datasets
        rm -f /var/lib/redis/nodes.conf*
        rm -f /var/lib/redis/dump.rdb*
        rm -rf /var/lib/redis/appendonlydir*

        # Ensure directory permissions are clean
        mkdir -p /var/lib/redis
        chown -R redis:redis /var/lib/redis
    '
done

echo "=================================================="
echo "Stage 2: Deploying Fresh Redis Cluster Configuration"
echo "=================================================="

for i in {1..6}; do
    NAME="redis-node-${i}"
    echo "Configuring ${NAME} for Redis Cluster..."
    orb -m "${NAME}" -u root bash -c '
        cat << "EOF" > /etc/redis/redis.conf
# Redis Cluster Lab Configuration (Port 6379, Cluster Bus 16379)
port 6379
bind 0.0.0.0
protected-mode no
daemonize no
supervised systemd
dir /var/lib/redis

# Cluster Settings
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000

# Persistence & Durability
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# Memory Limits
maxmemory 256mb
maxmemory-policy allkeys-lru
EOF

        # Ensure permissions
        chown -R redis:redis /etc/redis /var/lib/redis

        # Kernel Memory Overcommit
        sysctl -w vm.overcommit_memory=1 >/dev/null

        # Reload systemd and start Redis
        systemctl daemon-reload
        systemctl restart redis
        systemctl enable redis
    '

    # Verification
    PING_RESP=$(orb -m "${NAME}" redis-cli ping)
    CLUSTER_MODE=$(orb -m "${NAME}" redis-cli info cluster | grep cluster_enabled | tr -d "\r")
    echo "  --> ${NAME} Ping: ${PING_RESP}"
    echo "  --> ${NAME} Mode: ${CLUSTER_MODE}"
done

echo "=================================================="
echo "All 6 nodes are configured, running, and cluster-ready!"
echo "=================================================="
