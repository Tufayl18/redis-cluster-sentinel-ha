#!/usr/bin/env bash
# ==============================================================================
# Script: 01_provision_vms.sh (Cluster Lab)
# Purpose: Provision 6 fresh AlmaLinux 9 VMs on OrbStack and install Redis
# ==============================================================================

set -euo pipefail

echo "=================================================="
echo "Stage 1: Provisioning 6 AlmaLinux 9 VMs in OrbStack"
echo "=================================================="

for i in {1..6}; do
    NAME="redis-node-${i}"
    if orb list -q | grep -Fxq "${NAME}"; then
        echo "VM ${NAME} already exists. Ensuring it is running..."
        orb start "${NAME}" || true
    else
        echo "Creating ${NAME}..."
        orb create --memory 1G alma:9 "${NAME}"
    fi

    # Ensure Redis is installed on ${NAME}
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

echo "Pinging redis-node-2 from redis-node-1..."   
orb -m redis-node-1 ping -c 3 redis-node-2.orb.local
