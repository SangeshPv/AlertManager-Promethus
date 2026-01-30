#!/bin/bash
set -e

# --- CHECKS ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./auto_deploy.sh)"
  exit
fi

echo "========================================================"
echo "   AUTOMATED LAB DEPLOYMENT "
echo "========================================================"

# ========================================================
# [PART 1] DEPENDENCIES & INCUS INSTALLATION
# ========================================================
echo "--- [Part 1] Installing Dependencies and Incus ---"

# 1. Install Dependencies
apt-get update
apt-get install -y spice-vdagent spice-webdavd wget btrfs-progs curl tar

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
