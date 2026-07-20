#!/bin/bash
set -euo pipefail
trap 'echo "Execution failed at line $LINENO. Exiting."; exit 1' ERR
cd "$(dirname "$0")"

# --- CHECKS ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./auto_deploy.sh)"
  exit 1
fi

echo "========================================================"
echo "   AUTOMATED LAB DEPLOYMENT"
echo "========================================================"

echo "--- Running Part 1: install Incus ---"
./incus.sh

echo "--- Running Part 2: deploy containers ---"
./deploy_containers.sh

echo "--- Running Part 3: configure containers ---"
./container_config.sh

echo "========================================================"
echo "   DEPLOYMENT COMPLETE"
echo "========================================================"
