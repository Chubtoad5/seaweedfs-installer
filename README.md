# SeaweedFS Installer

A bash automation script that deploys a self-contained, production-ready SeaweedFS file storage stack in a Docker environment. A Caddy sidecar container provides reverse proxy, self-signed TLS, basic authentication, and a web-based landing page. An optional monitoring stack (Grafana, Loki, Prometheus) and message broker (SeaweedMQ) can also be deployed.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Usage](#usage)
  - [Quick Start](#quick-start)
- [Examples](#examples)
- [Configuration Variables](#configuration-variables)
- [Service Endpoints](#service-endpoints)
- [Behavior Notes](#behavior-notes)
  - [Exit codes](#exit-codes)
  - [Install-state file](#install-state-file)
  - [Firewall and SELinux handling](#firewall-and-selinux-handling)
  - [Security notes](#security-notes)
- [Known Issues](#known-issues)

---

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
- Automatically detects air-gapped mode when `swfs-save-version.txt` is present in the script directory; the archive may be renamed before transfer without breaking detection
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
  help              | Display this help message (exit 0)
  install           | Install and configure SeaweedFS and Caddy (Docker Compose). CLUSTER_MODE=cluster makes this a cluster-ready control plane.
  join              | Join this host to an existing cluster as a discrete volume node (requires -master)
  save              | Prepare offline archive for air-gapped deployment
  uninstall         | Uninstall SeaweedFS and Caddy including data and configuration (auto-detects a volume node)

Options:
  push              | Push SeaweedFS and Caddy images to a local registry, must include -registry option
  -registry         | Registry credentials for pushing or pulling from local registry (Format: -registry [registry:port username password])
  -master           | Control-plane master to join (join only). Format: -master <host-or-ip>:9333
```

Unknown arguments are rejected with a usage error (exit 1). `push` without `-registry` is rejected.

### Commands

#### `install`

Installs Docker, SeaweedFS, Caddy, and optionally the monitoring stack and SeaweedMQ from the internet.

- If `swfs-save-version.txt` is present in the same directory as `install-seaweedfs`, air-gapped install mode activates automatically (this file is bundled in the archive and extracted alongside the script). The sentinel is sanity-checked: if it is present but the image archives are missing, install aborts with instructions; set `SWFS_FORCE_ONLINE=true` to ignore a stale sentinel.
- If `-registry` is specified, containers are pulled from the local registry instead of Docker Hub
- Re-running `install` reconciles instead of duplicating: Samba/NFS config blocks are marker-tagged and replaced (never appended twice), changed bind-mounted configs (Caddyfile, monitoring configs) trigger a restart of the affected container, and features toggled off since the previous install (`ENABLE_MQ`, `ENABLE_MONITORING`, `ENABLE_SMB`, `ENABLE_NFS`) are torn down (`--remove-orphans` plus recorded-state cleanup)
- When **firewalld** (Rocky/RHEL, openSUSE Leap) or **UFW** (Ubuntu) is active, the ports for the enabled services are opened and recorded — see [Firewall and SELinux handling](#firewall-and-selinux-handling)
- When **SELinux is enforcing** and SMB is enabled, the `samba_share_fusefs` boolean is set (prior value recorded for uninstall)

**Configuration paths after installation:**

| Path | Contents |
|:-----|:---------|
| `/opt/seaweedfs/seaweedfs-compose.yaml` | Docker Compose file for SeaweedFS, Caddy, SeaweedMQ, and FUSE mount |
| `/opt/seaweedfs/mini/` | All SeaweedFS user data |
| `/opt/seaweedfs/monitoring-credentials.env` | S3/Loki/Prometheus credentials for external agents (when monitoring is enabled; mode 600) |
| `/opt/seaweedfs/.install-state` | Install-state record used by uninstall/re-install (mode 600) — see [Install-state file](#install-state-file) |
| `/opt/caddy/Caddyfile` | Caddy reverse proxy configuration |
| `/opt/caddy/srv/index.html` | Caddy web landing page |
| `/opt/monitoring/docker-compose.yml` | Docker Compose file for the monitoring stack |

#### `save`

Creates an offline archive (`swfs-save.tar.gz`) for air-gapped deployment. The archive includes:
- Docker engine and cli package for t he host OS version
- `swfs-save-version.txt` — version manifest with creation timestamp and the list of saved container image names
- Container images: SeaweedFS, Caddy, and (when `ENABLE_MONITORING=true`) Loki, Grafana, and Prometheus
- Package installers for Samba and NFS
- Any binaries listed in `ARTIFACTS_TO_DOWNLOAD`
- A `LICENSES/` directory: a third-party component manifest and, when the monitoring stack is bundled, an
  **AGPL-3.0 written offer** for the redistributed Grafana and Loki images plus (by default) their pinned
  **corresponding source** tarballs. Tune with:
  - `BUNDLE_COPYLEFT_SOURCE` (default `true`) — set `false` to ship the written offer only (no source tarballs)
  - `LICENSE_OFFER_CONTACT` — the contact named in the written offer

To use the archive on the target machine (the archive may be renamed before transfer):
```bash
tar xzf <archive-name>.tar.gz
sudo ./install-seaweedfs install
```

#### `uninstall`

Stops and removes all containers, then deletes all configuration and data directories. Samba/NFS/user cleanup is driven by the **recorded install state** (`/opt/seaweedfs/.install-state`), not by the `ENABLE_*` environment at uninstall time:

- The seaweedfs share block is removed from `/etc/samba/smb.conf` by its markers — the host's `smb.conf` is never deleted or wholesale-replaced, so running `uninstall` twice is a safe no-op
- The system user is removed **only if this installer created it**; a pre-existing account is kept (its Samba password entry is still removed)
- `/etc/fuse.conf` is restored according to what install actually did (created / backed up / untouched)
- Firewall rules (firewalld/UFW) added by install are removed — exactly the recorded set, never pre-existing rules
- A changed `samba_share_fusefs` SELinux boolean is restored to its recorded prior value
- The installer logs out of the registry it logged into; set `SWFS_REMOVE_IMAGES=true` to also `docker rmi` the container images this installer loaded
- The install log (contains credentials) is removed; the uninstall log is written mode 600
- Installs made by versions **before** the state file existed fall back to `ENABLE_*` plus on-disk evidence (marker/share present) and never remove user accounts

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

# Air-gapped install (swfs-save-version.txt must be present in the same directory)
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
| `SWFS_IMAGE` | `chrislusf/seaweedfs:4.30` | Container image for SeaweedFS (pinned for reproducible online/air-gapped installs; override to track a newer release) |
| `CADDY_IMAGE` | `caddy:2.11.3` | Container image for Caddy (pinned; override to track a newer release) |
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
| `NFS_META_REFRESH_SEC` | `30` | NFS re-export cache-coherence interval (seconds). The server drops its dentry/inode cache every N seconds so writes made *outside* the NFS path (filer HTTP API, S3, web uploader, another node) become visible to NFS clients within ~N seconds. `0` disables it. See [NFS consistency model](#nfs-consistency-model). |
| `ENABLE_MQ` | `true` | Deploy SeaweedMQ message broker |
| `MQ_BROKER_PORT` | `17777` | TCP port for SeaweedMQ broker |
| `S3_BUCKET` | `charlie` | Default S3 bucket name |
| `EXTRA_BUCKETS` | `""` | Space-separated list of additional S3 bucket names to create at install time. Useful for pre-creating per-cluster Velero buckets when the cluster inventory is known. Buckets are deduplicated against `S3_BUCKET` and `LOKI_BUCKET`. |
| `S3_USER` | `$SWFS_USER` | S3 API username |
| `S3_ACCESS_KEY` | *(randomly generated)* | S3 access key (`openssl rand -hex 8`); set explicitly to pin a stable key across re-installs |
| `S3_SECRET_KEY` | *(randomly generated)* | S3 secret key (`openssl rand -hex 16`); set explicitly to pin a stable key across re-installs |
| `ARTIFACTS_TO_DOWNLOAD` | `""` | Space-separated list of URLs to download and upload to the default Filer path |
| `VOLUME_INDEX` | `""` | Optional volume index mode `[memory\|leveldb\|leveldbMedium\|leveldbLarge]`. `leveldb` lowers volume-server RAM for many small files on edge hosts. Empty = `weed mini` default (`memory`). |
| `VOLUME_SIZE_LIMIT_MB` | `""` | Optional cap (MB) after which the master stops directing writes to a volume. Empty = `weed mini` auto-sizing (64–1024 MB). |
| `MGMT_IP` | *(first host IP)* | IP used as the Caddy `default_sni` fallback and cluster advertise address. Overridable (honored when passed by ap-tools or set explicitly). |
| `SWFS_FORCE_ONLINE` | `false` | Ignore a `swfs-save-version.txt` sentinel in the working directory and stay in online mode (recover from a stale sentinel, e.g. on a build host that ran `save`). |
| `SWFS_REMOVE_IMAGES` | `false` | `uninstall` only: also `docker rmi` the container images this installer loaded (recorded in the install-state file). |

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

## Behavior Notes

### Exit codes

The script exits `0` only when the requested operation actually succeeded. Critical-path failures — `docker compose up`, the Filer not becoming ready within 120 s, S3 credential/bucket configuration, package installation, image pull/push/load, save-archive creation, registry login — abort the run with a non-zero exit code and an `ERROR:` message (also appended to the log). Callers such as `ap-tools` can rely on the exit code. Non-critical issues (e.g. Loki slow to report ready, artifact upload failures) are logged as `WARNING` and do not fail the install.

### Install-state file

`install` records what it actually changed on the host in `/opt/seaweedfs/.install-state` (mode 600, `KEY=value` lines). Keys include:

| Key | Meaning |
|:----|:--------|
| `STATE_VERSION`, `INSTALL_DATE`, `NODE_ROLE` | Bookkeeping; `NODE_ROLE` is `control` or `volume` (join) |
| `SMB_CONFIGURED` / `NFS_CONFIGURED` / `MONITORING_CONFIGURED` / `MQ_CONFIGURED` | Which features this installer configured |
| `SMB_SERVICE_NAME` / `NFS_SERVICE_NAME` / `SMB_SHARE_NAME` / `FILER_DIR_NAME` | Names resolved at install time, reused at uninstall |
| `SWFS_USER_NAME` / `SWFS_USER_CREATED` | The SMB user and whether **this installer** created the account |
| `FUSE_CONF_ACTION` | `created` / `backed_up` / `untouched` — how `/etc/fuse.conf` was handled |
| `FIREWALLD_ADDED_PORTS` / `FIREWALLD_ADDED_SERVICES` / `UFW_ADDED_PORTS` | Exactly the firewall entries this installer added |
| `SELINUX_SAMBA_FUSEFS_PRIOR` | Prior value of the boolean, if this installer changed it |
| `REGISTRY_LOGIN` / `LOADED_IMAGES` / `LOADED_MONITORING_IMAGES` | Registry session and images for uninstall cleanup |

Uninstall and re-install reconciliation read this file; deleting it degrades uninstall to the conservative legacy fallback (evidence-based, never removes user accounts).

### Firewall and SELinux handling

- **firewalld** active (default on Rocky/RHEL and openSUSE Leap 16): install opens the ports for enabled features (admin/master/filer/S3, MQ, monitoring, cluster ports) via `--permanent --add-port`, plus the `samba` and `nfs`/`rpc-bind`/`mountd` services. Only entries the installer actually **adds** are recorded; pre-existing rules are never claimed. Re-install closes recorded entries for features you toggled off; uninstall removes exactly the recorded set.
- **UFW** active (Ubuntu): equivalent port rules are added with a `seaweedfs-installer` comment. Note UFW cannot model the NFSv3 dynamic `mountd` port — pin `mountd` or use firewalld if remote NFSv3 clients are blocked.
- **Neither active:** no firewall changes are made (a notice is printed).
- **SELinux enforcing** (Rocky/RHEL, Leap 16): with SMB enabled, `samba_share_fusefs` is set so `smbd` may serve the FUSE-mounted share (prior value recorded and restored at uninstall). If the boolean/policy is unavailable, a loud warning with the exact remediation is printed. With NFS enabled, a warning is printed if `nfs_export_all_rw` is `off`.

### Security notes

- The install log (`seaweedfs-install.log`) contains the full credentials and is written mode **600**; the console output masks passwords and S3 keys. Uninstall removes the install log.
- The Caddy landing page is served **unauthenticated** and no longer embeds the SMB password — the Windows `net use` example uses `*` to prompt for it.
- `docker login` uses `--password-stdin`; registry passwords are not echoed.
- `/opt/monitoring/loki/loki-config.yaml` embeds the S3 keys and is readable only by the Loki container user (UID 10001) and root; monitoring data directories are owned per container user (Loki 10001, Prometheus 65534, Grafana 472, mode 750) instead of world-writable.

### Per-distro service and package names

| Distro family | SMB service | NFS service | NFS server package |
|:--------------|:------------|:------------|:-------------------|
| Ubuntu / Debian | `smbd` | `nfs-kernel-server` | `nfs-kernel-server` |
| RHEL / CentOS / Rocky / AlmaLinux / Fedora | `smb` | `nfs-server` | `nfs-utils` |
| SLES / openSUSE Leap | `smb` | `nfs-server` | `nfs-kernel-server` |

The NFS server **package** is selected per distro in both the `install` and `save` paths (a save archive built on Rocky bundles `nfs-utils`).

## Known Issues

### NFS consistency model

The NFS share is a **knfsd re-export of the `weed mount` FUSE filesystem**. This makes it
behave differently from a native filesystem in one specific way you should understand before
relying on it for multi-writer workflows.

**Writes made *through* the NFS mount are coherent** between all NFS clients immediately —
they share the single NFS server (`knfsd`) on the SeaweedFS host, whose cache is updated by
the write itself.

**Writes made *outside* the NFS path are only *eventually* consistent.** "Outside" means the
filer HTTP API (`curl …filer:8888/…`), the S3 gateway, the Caddy web uploader, or another
cluster node. After such a write, NFS clients may keep showing a stale directory listing — a
deleted file still appears, or a newly uploaded file is not yet visible. Root cause (confirmed
by testing): the filer does not bump a directory's `mtime` when a child is added or removed, so
NFS clients never receive the "directory changed" signal that would invalidate their cached
listing, and the stale entries actually live in the **server's** kernel dentry/inode cache as
served by `knfsd`. No NFS *client* mount option fixes this (`noac`, `actimeo=0`, `nordirplus`,
and `lookupcache=none` were all tested and do not help), nor does any `weed mount`
`-cacheMetaTtlSec` value or a newer `weed` version.

**Mitigation (default on).** The installer enables a small systemd timer
(`seaweedfs-nfs-meta-refresh.timer`) that drops the server's dentry/inode cache
(`sync; echo 2 > /proc/sys/vm/drop_caches`) every **`NFS_META_REFRESH_SEC`** seconds (default
`30`). This bounds out-of-band-write visibility to roughly that interval. Tune it lower for
fresher listings (at the cost of more frequent cache drops) or set `NFS_META_REFRESH_SEC=0` to
disable. Inspect it with:

```bash
systemctl status seaweedfs-nfs-meta-refresh.timer
systemctl list-timers seaweedfs-nfs-meta-refresh.timer
```

**Want immediate (0-second) consistency for out-of-band writes?** Skip NFS on that client and
have it run its own `weed mount` against the filer instead — the FUSE layer subscribes to filer
metadata events and reflects changes in real time (the re-export is the only lossy hop). The
NFS export remains the simplest option and is ideal for read-mostly or NFS-only-writer use.

> The export line uses `fsid=1` (required — a FUSE filesystem has no stable device UUID for
> `knfsd` to derive filehandles from; without it `exportfs` warns and clients hit `ESTALE`
> across a `weed mount`/server restart). `fsid=1` belongs in the server's `/etc/exports`, not
> the client's `/etc/fstab`.

### Hung FUSE mount

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

---

## Upstream / Credits

This project automates the following open-source software; all credit to their authors. See [NOTICE](NOTICE) for
the full third-party list + licenses.

- SeaweedFS (Apache-2.0), Caddy (Apache-2.0), Prometheus (Apache-2.0), Docker (Apache-2.0)
- Optional monitoring: **Grafana (AGPL-3.0)** + **Grafana Loki (AGPL-3.0)** — when bundled/pushed, retain their license text and provide the corresponding source or a written offer per the AGPL

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
