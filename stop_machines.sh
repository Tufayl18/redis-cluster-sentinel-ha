#!/usr/bin/env bash

for i in {1..6}; do
    NAME="redis-node-${i}"
    echo "Stopping ${NAME} (if running)..."
    orb stop "${NAME}" || true
done