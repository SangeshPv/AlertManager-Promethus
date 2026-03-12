# Auto Deploy Lab – Documentation

## What is this?

This script sets up a fully working network monitoring lab on your machine — automatically. You run one command, and it handles everything: installing the container runtime, spinning up four containers, configuring each service, and wiring them all together. By the time it finishes, you have a live Prometheus stack monitoring a simulated network switch.

It was written to remove the tedium of setting up this kind of environment manually, which involves a lot of steps that are easy to get wrong. Instead of following a 10-page guide, you just run the script and wait.

---

## The Big Picture

The lab has four containers, each playing a specific role:

```
┌─────────────────────────────────────────────────────────┐
│                        HOST MACHINE                     │
│                                                         │
│  ┌──────────┐    SNMP     ┌──────────────┐             │
│  │  switch  │◄────────────│ SNMPExporter │             │
│  │(SNMPv3   │   port 161  │  port 9116   │             │
│  │ target)  │             └──────┬───────┘             │
│  └──────────┘                    │ metrics              │
│                                  ▼                      │
│                          ┌───────────────┐              │
│                          │     cnt2      │              │
│                          │  (Prometheus) │              │
│                          │   port 9090   │              │
│                          └───────┬───────┘              │
│                                  │ alerts               │
│                                  ▼                      │
│                          ┌───────────────┐              │
│                          │ alertmanager  │              │
│                          │   port 9093   │              │
│                          └───────────────┘              │
└─────────────────────────────────────────────────────────┘
```

- **switch** is the device being monitored. It runs a real SNMP daemon, so it behaves like an actual network switch.
- **SNMPExporter** sits in the middle and translates SNMP data into a format Prometheus can understand.
- **cnt2** runs Prometheus, which polls the exporter every 30 seconds and stores the results.
- **alertmanager** receives alerts from Prometheus — for example, if the switch goes down — and sends you an email.

All four containers live on an internal network bridge (`incusbr0`) and can talk to each other freely. From outside the host, you reach them through their assigned IPs on that bridge.

---

## Before You Run It

A few things need to be in place first.

**Your machine needs to be running Ubuntu 22.04 or 24.04.** Other distributions aren't supported because the script pulls packages from Ubuntu-specific repositories.

**You need at least 4 GB of RAM and around 25 GB of free disk space.** The script creates a 20 GB storage pool for the containers, and the services themselves aren't light — especially the SNMPExporter container, which compiles Go code during setup.

**Internet access is required throughout.** Container images, binaries, and Go modules are all downloaded at runtime. If your connection drops mid-way, the script will fail.

**The script must be run as root.** Incus requires root to install and initialise. Run it with `sudo ./auto_deploy.sh`.

**Fill in your email details before running.** Near the bottom of the script, there's a section for Alertmanager's email configuration. You'll need to replace the placeholder values with your real Gmail address and an App Password. A regular Gmail password won't work here — Google requires you to generate a dedicated App Password, which you can do at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords). Two-factor authentication must be enabled on the account first.

---

## Running the Scripts in Parts

If you prefer more control over the deployment — or if something goes wrong halfway through — the setup is split into three separate scripts that you can run independently, in order.

### Part 1 — Install Incus (`incus.sh`)

This is the foundation. It installs all host dependencies, sets up the Zabbly repository, installs Incus, and initialises it with the bridge network and storage pool. You only ever need to run this once per machine.

```bash
sudo ./incus.sh
```

**What to check when it's done:**
```bash
incus version
incus network list
incus storage list
```

You should see `incusbr0` listed as a network and `default` as a storage pool. If either is missing, do not proceed to Part 2 — something went wrong during initialisation.

---

### Part 2 — Deploy the Containers (`deploy_containers.sh`)

This script creates the four containers (`switch`, `cnt2`, `SNMPExporter`, `alertmanager`), starts them, and waits for them to come online. It also fetches and prints each container's IP address so you know what you're working with before configuration begins.

```bash
sudo ./deploy_containers.sh
```

**What to check when it's done:**
```bash
incus list
```

All four containers should show a **RUNNING** status with an IPv4 address assigned. If any container is missing an IP, wait another 10–15 seconds and run `incus list` again — occasionally a container takes a little longer to get an address from the bridge.

> **Note:** Do not run Part 2 more than once without cleaning up first. Running it a second time will fail because the containers already exist. If you need to start fresh, delete them first:
> ```bash
> incus delete --force switch cnt2 SNMPExporter alertmanager
> ```

---

### Part 3 — Configure the Services (`containers_config.sh`)

This is the longest part. It installs and configures Prometheus, the SNMP Exporter, SNMPv3 on the switch, and Alertmanager inside their respective containers. The container IPs are detected automatically at the start of the script, so no manual input is needed.

```bash
sudo ./containers_config.sh
```

This step takes the most time — mainly because the SNMP Exporter generator compiles from Go source, which can take 3–5 minutes on its own. The script will appear to hang during this step; that's normal.

**What to check when it's done:**
```bash
incus exec cnt2 -- systemctl status prometheus
incus exec SNMPExporter -- systemctl status snmp_exporter
incus exec alertmanager -- systemctl status alertmanager
incus exec switch -- systemctl status snmpd
```

All four should show **active (running)**. Then open Prometheus in your browser at `http://<CNT2_IP>:9090/targets` and confirm the `snmp` job shows **UP**.

---

### Running Order Summary

| Step | Script | Can be re-run? |
|---|---|---|
| 1 | `incus.sh` | Only if Incus is fully removed first |
| 2 | `deploy_containers.sh` | Only after deleting existing containers |
| 3 | `containers_config.sh` | Yes — safe to re-run to reapply config |

If you just want the full automated deployment in one go, you can still use the combined `auto_deploy.sh` script instead.

---

## What the Script Actually Does

### Installing Incus and the base packages

The first thing the script does is install a handful of packages on your host machine. Most of these are standard utilities (`wget`, `curl`, `tar`), but a couple are worth noting: `jq` is used later to extract container IP addresses from Incus's JSON output, and `btrfs-progs` is needed because the script uses Btrfs as the storage backend for containers.

After that, it adds the Zabbly repository — the official source for Incus packages — and installs Incus itself.

Incus is then initialised automatically using a preset configuration. This skips the usual interactive setup wizard and creates everything needed upfront: a bridge network, a storage pool, and a default container profile. The storage pool is set to 20 GB, which is enough for four Ubuntu containers running the services we need.

Once that's done, the four containers are created and started. The script waits 20 seconds at this point to give them time to fully boot and pick up IP addresses before it tries to configure them.

### Setting up Prometheus on cnt2

Prometheus is downloaded as a pre-built binary and installed to `/usr/local/bin/`. The script also handles the less obvious setup steps that are easy to miss — moving the console templates before cleaning up the download directory, creating a dedicated `prometheus` system user, and setting ownership on the config and data directories.

The configuration tells Prometheus to scrape SNMP metrics every 30 seconds through the SNMP Exporter, and to send any alerts to Alertmanager. There's also a metric filter in place that keeps only interface traffic counters (`ifInOctets`, `ifOutOctets` and their high-capacity variants), which keeps the data lean for a lab environment.

One alert rule is configured out of the box: if the switch stops responding for more than 30 seconds, an alert called `SwitchDown` fires.

Prometheus runs as a systemd service and starts automatically on boot.

### Setting up the SNMP Exporter

This is the most time-consuming part of the deployment. Rather than using a generic pre-built config, the script generates a custom one using the SNMP Exporter's generator tool. This matters because the configuration needs to match the exact SNMPv3 credentials and OID walks you're using.

The generator is compiled from source inside the container using Go, which can take anywhere from 3 to 5 minutes depending on your machine and network speed. This is expected — don't assume something has gone wrong if you see it sitting there for a while.

The SNMPv3 credentials used are:

| Setting | Value |
|---|---|
| Username | `Hero` |
| Auth protocol | SHA |
| Password | `Hero12345` |
| Privacy protocol | AES |
| Privacy password | `Hero12345` |

Once the config is generated, it's copied to `/etc/snmp_exporter/snmp.yml` and the exporter is started as a systemd service on port 9116.

### Configuring the switch

The switch container runs `snmpd`, the standard Net-SNMP daemon. The script creates the SNMPv3 user `Hero` using `net-snmp-create-v3-user`, writes a minimal config that allows read-only access, and opens UDP port 161 through `ufw`. That's all a device needs to be a valid SNMP target.

### Setting up Alertmanager

Alertmanager is downloaded and configured to route alerts to an email address via Gmail's SMTP server. The routing logic groups alerts by name, waits 30 seconds before sending the first notification in a group, and repeats every 5 seconds after that — which is aggressive, but fine for a lab where you want to see things fire quickly.

There's also an inhibition rule that suppresses warning-level alerts when a critical alert is already firing for the same instance, so your inbox doesn't get flooded with redundant messages.

---

## Accessing the Services

When the script finishes, it prints the IP addresses of each service. You can also get them at any time by running:

```bash
incus list
```

The addresses will look something like `10.x.x.x`. Open them in a browser **from the host machine** — these IPs are on an internal bridge network and aren't routable from other devices on your network.

| Service | Port | What you'll find there |
|---|---|---|
| Prometheus | 9090 | Metric queries, targets, alert rules |
| SNMP Exporter | 9116 | Raw exporter metrics and SNMP query tool |
| Alertmanager | 9093 | Active alerts, silences, and routing status |

To confirm everything is wired up correctly, open Prometheus and go to **Status → Targets**. The `snmp` job should show a green **UP** state. If it's red, something in the SNMP path isn't working — see below.

---

## Troubleshooting

**Prometheus won't start**

```bash
incus exec cnt2 -- systemctl status prometheus
incus exec cnt2 -- journalctl -u prometheus -n 50 --no-pager
```

**SNMP Exporter isn't running or the config is missing**

```bash
incus exec SNMPExporter -- systemctl status snmp_exporter
incus exec SNMPExporter -- ls /etc/snmp_exporter/
```

If `snmp.yml` isn't there, the generator step likely failed. Check the logs with `journalctl -u snmp_exporter`.

**The switch target shows DOWN in Prometheus**

Test whether the exporter can actually reach the switch over SNMP:

```bash
SWITCH_IP=$(incus list switch --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
incus exec SNMPExporter -- snmpwalk -v3 -u Hero -l authPriv -a SHA -A Hero12345 -x AES -X Hero12345 $SWITCH_IP 1.3.6.1.2.1.1
```

If this returns data, SNMP is working and the problem is in the Prometheus scrape config. If it times out, the issue is between the two containers — check that `snmpd` is running on the switch with `incus exec switch -- systemctl status snmpd`.

**Alertmanager isn't sending emails**

Double-check that you replaced the placeholder credentials in the script before running it. Gmail specifically requires an App Password — your normal account password will be rejected. If you're unsure whether you set it up correctly, you can check the current config inside the container:

```bash
incus exec alertmanager -- cat /etc/alertmanager/alertmanager.yml
```

**Container IPs changed**

If you restart the host, containers may get different IPs. Always run `incus list` after a reboot to get the current addresses before trying to access anything.