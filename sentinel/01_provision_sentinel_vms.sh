#!/usr/bin/env bash
# ==============================================================================
# Script: 01_provision_sentinel_vms.sh
# Purpose: Provision 6 fresh AlmaLinux 9 VMs on OrbStack and install Redis
# Topology:
#   - redis-node-1 (Master)
#   - redis-node-2 (Replica 1)
#   - redis-node-3 (Replica 2)
#   - redis-node-4 (Dedicated Sentinel 1)
#   - redis-node-5 (Dedicated Sentinel 2)
#   - redis-node-6 (Dedicated Sentinel 3)
# ==============================================================================

set -euo pipefail

echo "=================================================="
echo "Stage 1: Provisioning 6 AlmaLinux 9 VMs in OrbStack"
echo "=================================================="

for i in {1..6}; do
    NAME="redis-node-${i}"
    # Use 'orb list -q' for clean, machine-parsable names without ANSI spinners
    if orb list -q | grep -Fxq "${NAME}"; then
        echo "VM ${NAME} already exists. Ensuring it is running..."
        orb start "${NAME}" || true
    else
        echo "Creating ${NAME}..."
        orb create --memory 1G alma:9 "${NAME}"
    fi

    # Ensure Redis is installed on ${NAME} (using POSIX built-in 'command -v' instead of 'which')
    if ! orb -m "${NAME}" command -v redis-server &>/dev/null; then
        echo "--> Installing Redis on ${NAME}..."
        orb -m "${NAME}" -u root bash -c '
            # 1. Add official Redis repository
            cat << "EOF" > /etc/yum.repos.d/redis.repo
[Redis]
name=Redis
baseurl=http://packages.redis.io/rpm/rockylinux9
enabled=1
gpgcheck=1
EOF

            # 2. Import Redis GPG key
            curl -fsSL https://packages.redis.io/gpg -o /tmp/redis.key
            rpm --import /tmp/redis.key
            rm -f /tmp/redis.key

            # 3. Install Redis engine & tools
            dnf install -y redis
        '
    else
        echo "--> Redis already installed on ${NAME}."
    fi
done

echo "=================================================="
echo "Stage 2: Verifying VM Network Connectivity"
echo "=================================================="

orb list

for i in {1..6}; do
    NAME="redis-node-${i}"
    IP=$(orb -m "${NAME}" ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
    VERSION=$(orb -m "${NAME}" redis-server --version | awk '{print $3}')
    echo "${NAME} -> IP: ${IP} | Engine: ${VERSION}"
done

echo "VM provisioning and Redis installation complete!"
