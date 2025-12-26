#!/bin/bash
set -e

echo "--- [Part 2/3] Deploying Containers ---"

# 1. Create Containers
echo "Creating Incus containers (downloading images)..."
incus create images:ubuntu/noble/cloud switch
incus create images:ubuntu/noble/cloud cnt2
incus create images:ubuntu/noble/cloud SNMPExporter
incus create images:ubuntu/noble/cloud alertmanager

# 2. Start Containers
echo "Starting containers..."
incus start switch SNMPExporter alertmanager cnt2

# 3. Wait for Network
echo "Waiting 15s for containers to boot and acquire IP addresses..."
sleep 15

echo "--- Part 2 Complete: Containers are running ---"
incus list
