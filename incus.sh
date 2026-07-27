#!/bin/bash
set -e
trap 'echo "Execution failed at line $LINENO. Exiting."; exit 1' ERR

# --- CHECKS ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./incus.sh)"
  exit 1
fi

echo "========================================================"
echo "   AUTOMATED LAB DEPLOYMENT "
echo "========================================================"

# 0. OS Check
echo "--- Checking OS compatibility ---"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "ubuntu" ]; then
        if [ "$VERSION_ID" = "22.04" ] || [ "$VERSION_ID" = "24.04" ] || [ "$VERSION_ID" = "26.04" ]; then
            echo "  - Ubuntu $VERSION_ID detected. Proceeding with installation."
        else
            echo "Error: Only Ubuntu 22.04, 24.04, or 26.04 is supported. Detected Ubuntu $VERSION_ID."
            exit 1
        fi
    else
        echo "Error: Only Ubuntu is supported. Detected $ID."
        exit 1
    fi
else
    echo "Error: Cannot determine OS. /etc/os-release not found."
    exit 1
fi

# ========================================================
# [PART 1] DEPENDENCIES & INCUS INSTALLATION
# ========================================================
echo "--- [Part 1] Installing Dependencies and Incus ---"

# 1. Install Dependencies
apt-get update
# Added jq for processing JSON from incus
apt-get install -y spice-vdagent spice-webdavd wget btrfs-progs curl tar jq

# 2. Add Zabbly Repository
mkdir -p /etc/apt/keyrings
wget -qO - https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg --yes

cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.gpg
EOF

# 3. Install Incus
apt-get update
apt-get install -y incus

# 4. AUTOMATED INITIALIZATION
echo "--- Automating Incus Initialization ---"
if ! command -v incus &> /dev/null; then
    echo "Incus install failed!"
    exit 1
fi

cat <<EOF | incus admin init --preseed
config: {}
networks:
- config:
    ipv4.address: auto
    ipv6.address: auto
  description: ""
  name: incusbr0
  type: bridge
storage_pools:
- config:
    size: 20GB
  description: ""
  name: default
  driver: btrfs
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      network: incusbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
cluster: null
EOF