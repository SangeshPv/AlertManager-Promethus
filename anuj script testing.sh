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
# Deployment of the containers
echo "Deploying the containers"
incus create images:ubuntu/noble/cloud switch
incus create images:ubuntu/noble/cloud cnt2
incus create images:ubuntu/noble/cloud SNMPExporter
incus create images:ubuntu/noble/cloud alertmanager
echo "Starting containers..."
incus start switch SNMPExporter alertmanager cnt2

echo "Waiting 20s for containers to boot and acquire IP addresses..."
sleep 20
incus list

# configuring of the containers
echo "Configuring the containers..."
incus exec cnt2 bash
## Prometheus Installation on cnt2
echo "Installing Prometheus on cnt2..."
sudo apt-get update
sudo apt-get install -y wget tar nano
wget https://github.com/prometheus/prometheus/releases/download/v2.54.1/prometheus-2.54.1.linux-amd64.tar.gz
sudo tar xvf prometheus-2.54.1.linux-amd64.tar.gz
sleep 10
sudo tar xvf prometheus-2.54.1.linux-amd64.tar.gz
sudo mv prometheus-2.54.1.linux-amd64 /usr/local/bin/
sudo mv prometheus-2.54.1.linux-amd64/promtool /usr/local/bin/
rm prometheus-2.54.1.linux-amd64.tar.gz
sudo mkdir /etc/prometheus
sudo mkdir /var/lib/prometheus
# Move Configuration Files
sudo mv prometheus-2.54.1.linux-amd64/prometheus.yml /etc/prometheus/
sudo mv prometheus-2.54.1.linux-amd64/consoles /etc/prometheus/
sudo mv prometheus-2.54.1.linux-amd64/console_libraries /etc/prometheus/
# prometheus.yml Configuration
sudo rm /etc/prometheus/prometheus.yml    
cat <<EOF | sudo tee /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: 'snmp'
    scrape_interval: 30s
    scrape_timeout: 20s
    metrics_path: /snmp
    params:
      module: [snmpv3_switch]
      auth: [public_v3]
    static_configs:
      - targets:
          - '10.12.242.150'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: '10.12.242.206:9116'  # SNMP Exporter's IP:port

    metric_relabel_configs:
      - source_labels: [ifIndex]
        regex: '(.*)'
        target_label: interface
      - source_labels: [__name__]
        regex: '^if(HC)?(In|Out)Octets$'
        action: keep

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 10.12.242.213:9093

rule_files:
  - /etc/prometheus/alerts.yml
EOF
#Create a system user and group named prometheus:
sudo useradd --no-create-home --shell /bin/false prometheus
#Set Ownership
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
#Create a systemd Service File
cat <<EOF | sudo tee /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus Monitoring
After=network.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
            --config.file /etc/prometheus/prometheus.yml \
            --storage.tsdb.path /var/lib/prometheus/ \
            --web.console.templates=/etc/prometheus/consoles \
            --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF

# Alerts configuration 
cat <<EOF | sudo tee /etc/prometheus/alerts.yml 
groups:
  - name: SNMP Switch Alerts
    rules:
      - alert: SwitchDown
        expr: up{job="snmp"} == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "SNMP Switch is down"
          description: "The SNMP switch ({{ $labels.instance }}) is not responding."
EOF      
sudo systemctl daemon-reload
sudo systemctl start prometheus
sudo systemctl enable prometheus
sudo systemctl status prometheus




## SNMP Exporter Configuration
echo "Configuring SNMP Exporter..."
incus exec SNMPExporter bash
apt update
sudo apt install curl make nano -y unzip -y openssh-server  unzip build-essential libsnmp-dev golang-go git -y snmp snmp-mibs-downloader
sudo systemctl enable --now ssh
wget https://github.com/prometheus/snmp_exporter/releases/download/v0.29.0/snmp_exporter-0.29.0.linux-amd64.tar.gz
tar xvf snmp_exporter-0.29.0.linux-amd64.tar.gz
sudo cp snmp_exporter-0.29.0.linux-amd64/snmp_exporter /usr/local/bin/snmp_exporter
sudo chmod +x /usr/local/bin/snmp_exporter
sudo mkdir -p /etc/snmp_exporter
cd ~
git clone https://github.com/prometheus/snmp_exporter.git
cd ~/snmp_exporter/generator/
sudo rm generator.yml
cat <<EOF | sudo tee generator.yml
---
auths:
  public_v3:
    version: 3
    username: Hero
    security_level: authPriv
    auth_protocol: SHA
    password: Hero12345
    priv_protocol: AES
    priv_password: Hero12345

modules:
  snmpv3_switch:
    walk:
      - 1.3.6.1.2.1.1
      - 1.3.6.1.2.1.2
      - 1.3.6.1.2.1.31.1.1
    lookups:
      - source_indexes: [ifIndex]
        lookup: ifDescr
EOF
# Generate snmp_exporter.yml
cd ~/snmp_exporter/generator
mkdir -p mibs
curl -L -o mibs/SNMPv2-SMI.txt \
  https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/SNMPv2-SMI.txt

curl -L -o mibs/SNMPv2-TC.txt \
  https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/SNMPv2-TC.txt

curl -L -o mibs/SNMPv2-MIB.txt \
  https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/SNMPv2-MIB.txt

curl -L -o mibs/IF-MIB.txt \
  https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/IF-MIB.txt

curl -L -o mibs/IANAifType-MIB.txt \
  https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/IANAifType-MIB.txt
go run . generate --no-fail-on-parse-errors






## SNMPv3 Configuration
echo "Configuring SNMPv3..."
 incus exec switch bash
apt update
apt install nano
sudo apt install snmp snmpd snmp-mibs-downloader libsnmp-dev -y
sudo systemctl stop snmpd
sudo Stop SNMP Daemon 
# Create SNMPv3 User
sudo net-snmp-create-v3-user -ro -a SHA -A "Hero12345" -x AES -X "Hero12345" Hero
cat <<EOF | sudo tee /etc/snmp/snmpd.conf
rocommunity public
agentAddress udp:161
sysLocation "Incus Test Lab"
sysContact Test@example.com
# SNMPv3 user access
rouser Hero
agentAddress udp:161
sysLocation "Incus Test Lab"
EOF
sudo systemctl status snmpd
sudo systemctl start snmpd
sudo systemctl enable snmpd 
sudo ufw allow 161/udp
exit





## ALertmanager Configuration
echo "Configuring Alertmanager..."
incus exec AlertManager bash
apt update
apt install wget tar nano install -y openssh-server
sudo systemctl enable --now ssh
#Testing not so sure if needed
#chown -R ubuntu:ubuntu /home/ubuntu/.ssh
#chmod 700 /home/ubuntu/.ssh
#chmod 600 /home/ubuntu/.ssh/authorized_keys

wget https://github.com/prometheus/alertmanager/releases/download/v0.28.1/alertmanager-0.28.1.linux-amd64.tar.gz
tar xvf alertmanager-0.28.1.linux-amd64.tar.gz
tar xvf alertmanager-0.28.1.linux-amd64.tar.gz
cd alertmanager-0.28.1.linux-amd64
sudo mkdir -p /etc/alertmanager
cat <<EOF | sudo tee /etc/alertmanager/alertmanager.yml
sudo nano /etc/alertmanager/alertmanager.yml
route:
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 5s
  receiver: 'email-notifications'  # <- now sends to email by default

receivers:
  - name: 'email-notifications'
    email_configs:
      - to: 'enter email@gmail.com'
        from: 'enter email.mpct@gmail.com'
        smarthost: 'smtp.gmail.com:587'  # or your SMTP server
        auth_username: 'enter email.mpct@gmail.com'
        auth_password: 'generate 1 of your own '
        auth_identity: 'enter email.mpct@gmail.com'
        require_tls: true

  - name: 'web.hook'
    webhook_configs:
      - url: 'http://127.0.0.1:5001/'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'dev', 'instance']
EOF
#Create a systemd Service File
cat <<EOF | sudo tee /etc/systemd/system/alertmanager.service
[Unit]
Description=Prometheus Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/root/alertmanager-0.28.1.linux-amd64/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --cluster.listen-address=""
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

EOF
sudo systemctl daemon-reload
sudo systemctl enable alertmanager
sudo systemctl start alertmanager
sudo systemctl status alertmanager  
exit

# Access the Web UI with http://10.12.242.213:9093

