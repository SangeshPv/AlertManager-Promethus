#!/bin/bash
set -e

# --- CHECKS ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./deploy_containers.sh)"
  exit
fi

echo "========================================================"
echo "   PART 2 - DEPLOYING CONTAINERS"
echo "========================================================"

# ========================================================
# CHECK INCUS IS AVAILABLE
# ========================================================
if ! command -v incus &> /dev/null; then
    echo "Error: Incus is not installed. Run incus.sh first."
    exit 1
fi

# ========================================================
# CREATE AND START CONTAINERS
# ========================================================
echo "--- Creating containers ---"
incus create images:ubuntu/noble/cloud switch
incus create images:ubuntu/noble/cloud cnt2
incus create images:ubuntu/noble/cloud SNMPExporter
incus create images:ubuntu/noble/cloud alertmanager

echo "--- Starting containers ---"
incus start switch SNMPExporter alertmanager cnt2

echo "Waiting 20s for containers to boot and acquire IP addresses..."
sleep 20
incus list

# ========================================================
# VERIFY IPs
# ========================================================
echo "--- Fetching container IP addresses ---"
SWITCH_IP=$(incus list switch --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
SNMP_EXPORTER_IP=$(incus list SNMPExporter --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
ALERTMANAGER_IP=$(incus list alertmanager --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
CNT2_IP=$(incus list cnt2 --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')

if [ -z "$SWITCH_IP" ] || [ -z "$SNMP_EXPORTER_IP" ] || [ -z "$ALERTMANAGER_IP" ] || [ -z "$CNT2_IP" ]; then
    echo "Error: Failed to get IP for one or more containers. Aborting."
    exit 1
fi

echo "========================================================"
echo "   PART 2 COMPLETE"
echo "========================================================"
echo "  switch:       $SWITCH_IP"
echo "  cnt2:         $CNT2_IP"
echo "  SNMPExporter: $SNMP_EXPORTER_IP"
echo "  alertmanager: $ALERTMANAGER_IP"
echo ""
echo "  Run containers_config.sh to continue."
echo "========================================================"