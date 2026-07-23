#!/bin/bash
set -e
trap 'echo "Execution failed at line $LINENO. Exiting."; exit 1' ERR

# --- CHECKS ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./cleanup.sh)"
  exit 1
fi

if ! command -v incus &> /dev/null; then
    echo "Incus is not installed. Nothing to clean up."
    exit 0
fi

echo "========================================================"
echo "   CLEANING UP LAB ENVIRONMENT"
echo "========================================================"

# 1. Stop and delete containers
CONTAINERS="switch cnt2 SNMPExporter alertmanager"
echo "--- Deleting containers ---"
incus stop switch cnt2 SNMPExporter alertmanager
for container in $CONTAINERS; do
    if incus info "$container" &>/dev/null; then
        echo "Deleting container: $container..."
        incus delete "$container" --force
    else
        echo "Container $container does not exist, skipping."
    fi
done

# 2. Delete network
NETWORK="incusbr0"
echo "--- Deleting network ---"
if incus network info "$NETWORK" &>/dev/null; then
    echo "Deleting network: $NETWORK..."
    incus network delete "$NETWORK"
else
    echo "Network $NETWORK does not exist, skipping."
fi

# 3. Delete storage pool
STORAGE_POOL="default"
echo "--- Deleting storage pool ---"
if incus storage info "$STORAGE_POOL" &>/dev/null; then
    echo "Deleting storage pool: $STORAGE_POOL..."
    incus storage delete "$STORAGE_POOL"
else
    echo "Storage pool $STORAGE_POOL does not exist, skipping."
fi

echo "========================================================"
echo "   CLEANUP COMPLETE"
echo "========================================================"