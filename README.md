# SeaweedFS Installer

A bash automation script that deploys a self-contained, production-ready SeaweedFS file storage stack in a Docker environment. A Caddy sidecar container provides reverse proxy, self-signed TLS, basic authentication, and a web-based landing page. An optional monitoring stack (Grafana, Loki, Prometheus) and message broker (SeaweedMQ) can also be deployed.

## Overview

The installer sets up the following services depending on configuration:

| Service | Container | Purpose |
|:--------|:----------|:--------|
| SeaweedFS Mini | `seaweed-mini` | All-in-one file server: Master, Volume, Filer, Admin UI, and S3 Gateway |
| Caddy | `seaweed-caddy` | Reverse proxy with self-signed TLS, basic auth, and web landing page |
| SeaweedMQ | `seaweed-mq` | Message broker (optional, enabled by default) |
| FUSE Mount | `seaweed-mount` | Mounts the Filer path on the host for SMB/NFS sharing (when SMB or NFS is enabled) |
| Loki | `loki` | Log aggregation, persisted to SeaweedFS S3 (optional monitoring) |
| Prometheus | `prometheus` | Remote-write metrics receiver (optional monitoring) |
| Grafana | `grafana` | Dashboards for logs and metrics (optional monitoring) |

## Features

- Automates Docker runtime installation based on detected OS release
- Deploys SeaweedFS `weed mini` with Admin UI, Master, Volume, Filer, S3 Gateway, and optional SMB/NFS shares
- Caddy provides self-signed TLS with auto-renewing certificates, basic authentication, and a web landing page
- Optional SeaweedMQ message broker for event streaming
- Optional monitoring stack: Grafana, Loki (log aggregation backed by SeaweedFS S3), and Prometheus (metrics remote-write receiver)
- Supports air-gapped deployments via a self-contained offline archive (`swfs-save.tar.gz`)
- Automatically detects air-gapped mode when `swfs-save.tar.gz` is present in the script directory
- Supports pushing container images to a local registry and pulling from it at install time
- Automatic download and upload of user-defined binaries to the default Filer directory

## Usage

### Quick Start

```bash
git clone https://github.com/Chubtoad5/seaweedfs-installer.git
cd seaweedfs-installer
chmod +x install-seaweedfs
sudo ./install-seaweedfs install
```

After installation, a summary with all service URLs, credentials, and API examples is printed to the console and saved to `seaweedfs-install.log`.

### Syntax

```
Usage: ./install-seaweedfs [command] [option]

Commands:
  help              | Display this help message
  install           | Install and configure SeaweedFS and Caddy (Docker Compose)
  save              | Prepare offline archive for air-gapped deployment
  uninstall         | Uninstall SeaweedFS and Caddy including data and configuration

Options:
  push              | Push SeaweedFS and Caddy images to a local registry, must include -registry option
  -registry         | Registry credentials for pushing or pulling from local registry (Format: -registry [registry:port username password])
```

### Commands

#### `install`

Installs Docker, SeaweedFS, Caddy, and optionally the monitoring stack and SeaweedMQ from the internet.

- If `swfs-save.tar.gz` is present in the same directory as `install-seaweedfs`, air-gapped install mode activates automatically
- If `-registry` is specified, containers are pulled from the local registry instead of Docker Hub

**Configuration paths after installation:**

| Path | Contents |
|:-----|:---------|
| `/opt/seaweedfs/seaweedfs-compose.yaml` | Docker Compose file for SeaweedFS, Caddy, SeaweedMQ, and FUSE mount |
| `/opt/seaweedfs/mini/` | All SeaweedFS user data |
| `/opt/seaweedfs/monitoring-credentials.env` | S3/Loki/Prometheus credentials for external agents (when monitoring is enabled) |
| `/opt/caddy/Caddyfile` | Caddy reverse proxy configuration |
| `/opt/caddy/srv/index.html` | Caddy web landing page |
| `/opt/monitoring/docker-compose.yml` | Docker Compose file for the monitoring stack |

#### `save`

Creates an offline archive (`swfs-save.tar.gz`) for air-gapped deployment. The archive includes:
- Docker runtime binaries (for the detected OS)
- Container images: SeaweedFS, Caddy, and (when `ENABLE_MONITORING=true`) Loki, Grafana, and Prometheus
- Package installers for Samba and NFS
- Any binaries listed in `ARTIFACTS_TO_DOWNLOAD`

To use the archive on the target machine:
```bash
tar xzf swfs-save.tar.gz
sudo ./install-seaweedfs install
```

#### `uninstall`

Stops and removes all containers, then deletes all configuration and data directories. Also reverts Samba and NFS configuration if those features were enabled during install.

> **Warning:** Uninstall is destructive and permanently deletes all SeaweedFS user data.

#### `push` option

When combined with `install` and `-registry`, images are pulled from the internet (or the local archive in air-gapped mode) and pushed to the specified local registry before the install proceeds. The registry must have the following projects pre-created:

| Project | Image | Required When |
|:--------|:------|:--------------|
| `chrislusf` | `chrislusf/seaweedfs` | Always |
| `library` | `library/caddy` | Always |
| `grafana` | `grafana/loki`, `grafana/grafana-oss` | `ENABLE_MONITORING=true` |
| `prom` | `prom/prometheus` | `ENABLE_MONITORING=true` |

#### `-registry` option

Provides local registry credentials used for both pushing and pulling containers. The registry TLS certificate is automatically retrieved and trusted.

## Examples

```bash
# Standard install from the internet
sudo ./install-seaweedfs install

# Install without monitoring stack
sudo ENABLE_MONITORING="false" ./install-seaweedfs install

# Install with custom credentials and hostname
sudo SWFS_USER="weeduser" SWFS_PASSWORD="weedpassword" HOST_FQDN="storage.mylab.com" \
  ./install-seaweedfs install

# Prepare an offline archive on an internet-connected machine
sudo ./install-seaweedfs save

# Prepare an offline archive without monitoring images
sudo ENABLE_MONITORING="false" ./install-seaweedfs save

# Air-gapped install (swfs-save.tar.gz must be present in the same directory)
sudo ./install-seaweedfs install

# Install pulling containers from a local registry
sudo ./install-seaweedfs install -registry myregistry:5000 user password

# Pull from internet, push to local registry, then install using local registry
sudo ./install-seaweedfs install push -registry myregistry:5000 user password

# Uninstall everything
sudo ./install-seaweedfs uninstall
```

### Passing Variables at Runtime

All user-defined variables can be passed as environment variables:

```bash
sudo SWFS_USER="admin" SWFS_PASSWORD="s3cr3t" ENABLE_MONITORING="false" \
  ./install-seaweedfs install -registry myregistry:5000 user password
```

## Configuration Variables

Edit the `install-seaweedfs` file and modify the `USER DEFINED VARIABLES` section, or pass any variable as an environment variable at runtime.

### Core Variables

| Variable | Default Value | Description |
|:---------|:-------------|:------------|
| `DEBUG` | `1` | When disabled (`0`), script runs in silent mode |
| `SWFS_IMAGE` | `chrislusf/seaweedfs:latest` | Container image for SeaweedFS |
| `CADDY_IMAGE` | `caddy:latest` | Container image for Caddy |
| `SWFS_USER` | `admin` | Username for Admin UI, Filer, Master, and Caddy basic auth |
| `SWFS_PASSWORD` | `changeme` | Password for Admin UI, Filer, Master, and Caddy basic auth |
| `HOST_FQDN` | `$(hostname).edge.lab` | FQDN for the host (e.g. `myhost.mydomain.com`) |
| `SWFS_ADMIN_FQDN` | `admin.$HOST_FQDN` | FQDN for the Admin UI and Caddy landing page |
| `SWFS_MASTER_FQDN` | `master.$HOST_FQDN` | FQDN for the SeaweedFS Master service |
| `SWFS_FILER_FQDN` | `filer.$HOST_FQDN` | FQDN for the SeaweedFS Filer service |
| `SWFS_S3_FQDN` | `s3.$HOST_FQDN` | FQDN for the SeaweedFS S3 endpoint |
| `SWFS_ADMIN_PORT` | `443` | TCP port for Admin UI |
| `SWFS_MASTER_PORT` | `9333` | TCP port for Master service |
| `SWFS_FILER_PORT` | `8888` | TCP port for Filer service |
| `SWFS_S3_PORT` | `8333` | TCP port for S3 endpoint |
| `DEFAULT_FILER_DIR_NAME` | `artifacts` | Default Filer directory for user data |
| `ENABLE_SMB` | `true` | Enable Samba (SMB) share with basic auth on the default Filer path |
| `ENABLE_NFS` | `true` | Enable NFS export (NFSv3, no authentication) of the default Filer path |
| `ENABLE_MQ` | `true` | Deploy SeaweedMQ message broker |
| `MQ_BROKER_PORT` | `17777` | TCP port for SeaweedMQ broker |
| `S3_BUCKET` | `charlie` | Default S3 bucket name |
| `S3_USER` | `$SWFS_USER` | S3 API username |
| `S3_ACCESS_KEY` | *(randomly generated)* | S3 access key (`openssl rand -hex 8`) |
| `S3_SECRET_KEY` | *(randomly generated)* | S3 secret key (`openssl rand -hex 16`) |
| `ARTIFACTS_TO_DOWNLOAD` | `""` | Space-separated list of URLs to download and upload to the default Filer path |

### Monitoring Stack Variables

> **Recommendation:** The monitoring stack deploys Grafana, Loki, and Prometheus as additional containers and requires additional host resources. Only enable it if you plan to use an external log or metrics collector such as Fluent Bit or a Prometheus remote-write agent to ship data to this host. If no external agents are configured, set `ENABLE_MONITORING="false"` to reduce overhead.
>
> When monitoring is enabled, a credentials file is written to `/opt/seaweedfs/monitoring-credentials.env` containing the S3 access key, Loki endpoint, and Prometheus endpoint — ready to be sourced by external tools or automation scripts.

| Variable | Default Value | Description |
|:---------|:-------------|:------------|
| `ENABLE_MONITORING` | `true` | Deploy Grafana, Loki, and Prometheus monitoring stack |
| `LOKI_IMAGE` | `grafana/loki:3.4.2` | Container image for Loki |
| `GRAFANA_IMAGE` | `grafana/grafana-oss:11.5.2` | Container image for Grafana |
| `PROMETHEUS_EXT_IMAGE` | `prom/prometheus:v3.2.1` | Container image for Prometheus |
| `GRAFANA_FQDN` | `grafana.$HOST_FQDN` | FQDN for Grafana UI (proxied through Caddy with TLS) |
| `GRAFANA_PORT` | `3000` | TCP port for Grafana |
| `LOKI_PORT` | `3100` | TCP port for Loki push/query (direct, no TLS) |
| `PROMETHEUS_EXT_PORT` | `9090` | TCP port for Prometheus remote-write receiver (direct, no TLS) |
| `LOKI_BUCKET` | `loki-logs` | SeaweedFS S3 bucket name used by Loki for log storage |
| `CLUSTER_NAME` | `edge-lab` | Cluster label applied to all Prometheus metrics and Loki logs |

## Service Endpoints

After a successful install, the following endpoints are available by IP address or by FQDN when DNS is configured:

| Service | Default URL | Auth Required |
|:--------|:-----------|:--------------|
| Landing Page | `https://<host-ip>:443` | No |
| Admin UI | `https://admin.<HOST_FQDN>:443` | Yes |
| Master UI | `https://master.<HOST_FQDN>:9333` | Yes |
| Filer UI / Browser | `https://filer.<HOST_FQDN>:8888/artifacts` | Yes |
| S3 Endpoint | `https://s3.<HOST_FQDN>:8333` | S3 key/secret |
| SeaweedMQ Broker | `<HOST_FQDN>:17777` | — |
| Grafana | `https://grafana.<HOST_FQDN>:3000` *(monitoring only)* | Yes |
| Loki | `http://<host-ip>:3100` *(monitoring only)* | No |
| Prometheus | `http://<host-ip>:9090` *(monitoring only)* | No |

All browser-accessible services use self-signed TLS issued by Caddy. To retrieve the Caddy root CA certificate for import into browsers or OS trust stores:

```bash
docker exec -it seaweed-caddy cat /data/caddy/pki/authorities/local/root.crt > seaweedfs-root-ca.crt
```

## Known Issues

In rare occurrences, the `seaweed-mount` container may fail to start with:

```
Error response from daemon: invalid mount config for type "bind": stat /mnt/seaweed: transport endpoint is not connected
```

This can happen when the host FUSE process becomes hung after an unexpected event such as a Docker crash or OOM kill.

**To resolve:**

1. Verify the mount point is hung:
```bash
ls -al /mnt/seaweed
ls -al /mnt/
```
You may see `ls: cannot access '/mnt/seaweed': Transport endpoint is not connected`
or a strange listing like `d?????????  ? ?    ?       ?            ? seaweed`

2. Identify the hung mount and any associated process:
```bash
mount | grep /mnt/seaweed || true
findmnt -T /mnt/seaweed -o TARGET,SOURCE,FSTYPE,OPTIONS || true
ps aux | egrep 'weed.*mount|seaweed|fuse' | grep -v egrep
lsof +D /mnt/seaweed 2>/dev/null | head
```

3. Unmount the hung device:
```bash
sudo umount -l /mnt/seaweed
```

4. Verify the directory listing returns to normal:
```bash
ls -al /mnt/seaweed
ls -al /mnt/
```

5. Restart Docker Compose:
```bash
sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d
```
