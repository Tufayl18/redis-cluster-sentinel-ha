#!/usr/bin/env bash
# ==============================================================================
# Script: 03_cluster_creation.sh (Cluster Lab)
# Purpose: Initialize 3 Masters + 3 Replicas Redis Cluster across 6 VMs
# ==============================================================================

set -euo pipefail

echo "=================================================="
echo "Stage 1: Retrieving IP addresses of all cluster nodes"
echo "=================================================="

ENDPOINTS=()
for i in {1..6}; do
    NAME="redis-node-${i}"
    IP=$(orb -m "${NAME}" ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
    echo "${NAME} IP: ${IP}"
    ENDPOINTS+=("${IP}:6379")
done

echo "=================================================="
echo "Stage 2: Creating Redis Cluster (3 Masters + 3 Replicas)"
echo "=================================================="

echo "Endpoints: ${ENDPOINTS[*]}"
orb -m redis-node-1 redis-cli --cluster create "${ENDPOINTS[@]}" --cluster-replicas 1 --cluster-yes

echo "=================================================="
echo "Stage 3: Verifying Cluster Health"
echo "=================================================="

orb -m redis-node-1 redis-cli cluster info
orb -m redis-node-1 redis-cli cluster nodes

echo "=================================================="
echo "Redis Cluster Created and Verified Successfully!"
echo "=================================================="
