#!/usr/bin/env bash
# ==============================================================================
# Script: 04_configure_tls_sentinel.sh
# Purpose: Configure 6 VMs into Secure, Fully-Encrypted TLS Redis Sentinel Topology:
#   - Generates CA, Server, and Client mTLS Certificates with SANs
#   - Enables TLS on Redis Port 6379 (tls-port 6379, port 0)
#   - Enables TLS on Sentinel Port 26379 (tls-port 26379, port 0)
#   - Encrypts replication traffic between Master & Replicas (tls-replication yes)
#   - Encrypts Sentinel monitoring & gossip (sentinel tls-replication yes)
#   - Symmetrical Authentication preserved:
#       * Redis Data Layer: "RedisMasterPass2026!"
#       * Sentinel Consensus: "SentinelPeerPass2026!"
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
echo "Stage 1: Discovering VM Dynamic IP Addresses"
echo "=================================================="

MASTER_IP=$(orb -m redis-node-1 ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)

if [[ -z "${MASTER_IP}" || "${MASTER_IP}" == "127.0.0.1" ]]; then
    echo "ERROR: Could not resolve valid network IP for redis-node-1. Aborting."
    exit 1
fi

echo "Master (redis-node-1) IP: ${MASTER_IP}"

# Collect all 6 VM IPs for Subject Alternative Names (SAN)
IP_LIST=""
for i in {1..6}; do
    IP=$(orb -m "redis-node-${i}" ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
    echo "  redis-node-${i} -> ${IP}"
    IP_LIST="${IP_LIST} IP:${IP},"
done
# Strip trailing comma
SAN_IPS="${IP_LIST%,}"

echo "=================================================="
echo "Stage 2: Generating PKI TLS Certificates on redis-node-1"
echo "=================================================="

orb -m redis-node-1 -u root bash -c "
set -euo pipefail
mkdir -p /etc/redis/tls
cd /etc/redis/tls

# 1. Generate Root CA
echo '--> Generating Root CA...'
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj '/CN=Redis-Sentinel-CA' -out ca.crt

# 2. OpenSSL Configuration with SAN
cat << 'EOF' > san.cnf
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = redis.orb.local

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.orb.local
IP.1 = 127.0.0.1
EOF

# Append all discovered VM IPs into san.cnf
EOF_SAN=\"${SAN_IPS}\"
idx=2
for ip_entry in \$(echo \"\${EOF_SAN}\" | tr ',' ' '); do
    raw_ip=\$(echo \"\${ip_entry}\" | cut -d':' -f2)
    echo \"IP.\${idx} = \${raw_ip}\" >> san.cnf
    idx=\$((idx + 1))
done

# 3. Generate Server Certificate & Sign with Root CA
echo '--> Generating Server Certificate (mTLS)...'
openssl genrsa -out redis.key 2048
openssl req -new -key redis.key -out redis.csr -config san.cnf
openssl x509 -req -in redis.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out redis.crt -days 3650 -sha256 -extfile san.cnf -extensions v3_req

# 4. Generate Client Certificate
echo '--> Generating Client Certificate...'
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr -subj '/CN=redis-client'
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days 3650 -sha256

# Set permissions: certs and client.key are readable by clients, private server/CA keys are locked
chmod 755 /etc/redis /etc/redis/tls
chmod 644 ca.crt redis.crt client.crt client.key
chmod 600 ca.key redis.key
chown -R redis:redis /etc/redis/tls

# Package bundle for peer nodes
tar -czf /tmp/redis-tls-bundle.tar.gz -C /etc/redis/tls .
"

echo "=================================================="
echo "Stage 3: Distributing TLS Bundle to Nodes 2 through 6"
echo "=================================================="

# Read the tarball from redis-node-1 into memory and stream to nodes 2..6
TAR_BASE64=$(orb -m redis-node-1 -u root base64 /tmp/redis-tls-bundle.tar.gz)

for i in 2 3 4 5 6; do
    NAME="redis-node-${i}"
    echo "--> Installing TLS certs on ${NAME}..."
    orb -m "${NAME}" -u root bash -c "
        mkdir -p /etc/redis/tls
        echo '${TAR_BASE64}' | base64 -d | tar -xzf - -C /etc/redis/tls
        chmod 755 /etc/redis /etc/redis/tls
        chmod 644 /etc/redis/tls/*.crt /etc/redis/tls/client.key
        chmod 600 /etc/redis/tls/ca.key /etc/redis/tls/redis.key
        chown -R redis:redis /etc/redis/tls
    "
done

echo "=================================================="
echo "Stage 4: Stopping Services & Clearing Cluster State"
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
echo "Stage 5: Configuring TLS on Data Layer (Nodes 1, 2, 3)"
echo "=================================================="

# 1. Master (redis-node-1)
echo "--> Configuring TLS Master (redis-node-1)..."
orb -m redis-node-1 -u root bash -c "cat << EOF > /etc/redis/redis.conf
# Plaintext port disabled
port 0
tls-port 6379

# TLS Certificates & Security
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients yes
tls-replication yes

bind 0.0.0.0
protected-mode yes
daemonize no
supervised systemd
dir /var/lib/redis

cluster-enabled no
maxmemory 256mb
maxmemory-policy allkeys-lru

appendonly yes
appendfilename \"appendonly.aof\"
appendfsync everysec

min-replicas-to-write 1
min-replicas-max-lag 10

requirepass ${REDIS_PASS}
masterauth ${REDIS_PASS}
EOF
chown -R redis:redis /etc/redis /var/lib/redis
"

# 2. Replicas (redis-node-2 and redis-node-3)
for i in 2 3; do
    NAME="redis-node-${i}"
    echo "--> Configuring TLS Replica (${NAME})..."
    orb -m "${NAME}" -u root bash -c "cat << EOF > /etc/redis/redis.conf
# Plaintext port disabled
port 0
tls-port 6379

# TLS Certificates & Security
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients yes
tls-replication yes

bind 0.0.0.0
protected-mode yes
daemonize no
supervised systemd
dir /var/lib/redis

cluster-enabled no
maxmemory 256mb
maxmemory-policy allkeys-lru

appendonly yes
appendfilename \"appendonly.aof\"
appendfsync everysec

min-replicas-to-write 1
min-replicas-max-lag 10

requirepass ${REDIS_PASS}
masterauth ${REDIS_PASS}

# Point to Master over TLS
replicaof ${MASTER_IP} 6379
EOF
chown -R redis:redis /etc/redis /var/lib/redis
"
done

echo "=================================================="
echo "Stage 6: Configuring TLS on Sentinel Quorum (Nodes 4, 5, 6)"
echo "=================================================="

for i in 4 5 6; do
    NAME="redis-node-${i}"
    echo "--> Configuring TLS Sentinel (${NAME})..."
    orb -m "${NAME}" -u root bash -c "
mkdir -p /etc/redis/sentinel
cat << EOF > /etc/redis/sentinel/sentinel.conf
# Plaintext port disabled
port 0
tls-port 26379

# TLS Configuration
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients yes
tls-replication yes

bind 0.0.0.0
protected-mode yes
daemonize no
supervised systemd
dir /tmp

# Monitoring Master over TLS
sentinel monitor mymaster ${MASTER_IP} 6379 2

# Authentication
sentinel auth-pass mymaster ${REDIS_PASS}
requirepass ${SENTINEL_PASS}
sentinel sentinel-pass ${SENTINEL_PASS}

# Timing
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel parallel-syncs mymaster 1
EOF
chown -R redis:redis /etc/redis
chmod 644 /etc/redis/sentinel/sentinel.conf
"
done

echo "=================================================="
echo "Stage 7: Starting TLS Services"
echo "=================================================="

echo "--> Starting Redis TLS Data Nodes (1, 2, 3)..."
for i in 1 2 3; do
    orb -m "redis-node-${i}" -u root systemctl restart redis
done

echo "--> Starting Sentinel TLS Daemons (4, 5, 6)..."
for i in 4 5 6; do
    orb -m "redis-node-${i}" -u root systemctl restart redis-sentinel
done

echo "=================================================="
echo "Fully Encrypted TLS Sentinel Setup Complete!"
echo "Master IP: ${MASTER_IP}"
echo "Plaintext TCP: DISABLED (port 0)"
echo "TLS Data Port: 6379"
echo "TLS Sentinel Port: 26379"
echo "=================================================="
