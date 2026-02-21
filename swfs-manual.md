# SeaweedFS Manual Installation Guide

This guide walks through manually deploying the SeaweedFS stack without the automation script. It mirrors what `install-seaweedfs` does under the hood, giving you full control at each step.

**What gets deployed (core):**

| Container | Image | Purpose |
|:----------|:------|:--------|
| `seaweed-mini` | `chrislusf/seaweedfs:latest` | All-in-one: Master, Volume, Filer, Admin UI, S3 Gateway |
| `seaweed-caddy` | `caddy:latest` | Reverse proxy with self-signed TLS and basic auth |

Optional add-ons are covered in their own sections below.

---

## Prerequisites

- **Supported OS:** Ubuntu 22.04 / 24.04, RHEL 9.x, SLES 15 / 16
- **Root or sudo access**
- **Docker with the Compose plugin** — see the install guide for your OS:
  - [Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
  - [RHEL](https://docs.docker.com/engine/install/rhel/)
  - [SLES](https://docs.docker.com/engine/install/sles/)

After installing Docker, enable and start the service:

```bash
sudo systemctl enable --now docker
```

Verify Docker and Compose are working:

```bash
docker version
docker compose version
```

---

## 1. Define Your Variables

Run these in your shell session before executing any commands below. All subsequent steps reference these variables.

```bash
# Authentication
SWFS_USER="admin"
SWFS_PASSWORD="changeme"

# Networking — replace with your server's actual IP and domain
HOST_IP="$(hostname -I | awk '{print $1}')"
HOST_FQDN="$(hostname).edge.lab"

# Derived FQDNs
SWFS_ADMIN_FQDN="admin.${HOST_FQDN}"
SWFS_MASTER_FQDN="master.${HOST_FQDN}"
SWFS_FILER_FQDN="filer.${HOST_FQDN}"
SWFS_S3_FQDN="s3.${HOST_FQDN}"

# Filer directory and S3
FILER_DIR="artifacts"
S3_BUCKET="mybucket"
S3_USER="${SWFS_USER}"
S3_ACCESS_KEY="$(openssl rand -hex 8)"
S3_SECRET_KEY="$(openssl rand -hex 16)"
```

> **Tip:** If using `sudo` for the commands below, either run as root (`sudo -i`) or prefix commands with `sudo -E` to preserve your environment variables.

---

## 2. Create Directories

```bash
sudo mkdir -p /opt/caddy
sudo mkdir -p /opt/seaweedfs/mini
```

---

## 3. Generate Caddy Password Hash

Caddy requires its own bcrypt-hashed password format. Use a temporary Caddy container to generate it:

```bash
CADDY_HASHED_PASSWORD=$(docker run --rm caddy:latest caddy hash-password --plaintext "${SWFS_PASSWORD}")
echo "Hashed password: ${CADDY_HASHED_PASSWORD}"
```

---

## 4. Create the Caddyfile

This is a simplified Caddyfile with no landing page. All four service endpoints are proxied with self-signed TLS. The filer directory and master require basic auth; S3 uses its own SigV4 key authentication.

```bash
sudo tee /opt/caddy/Caddyfile > /dev/null <<EOF
{
    default_sni ${HOST_IP}
}

${SWFS_ADMIN_FQDN}:443, https://${HOST_IP}:443 {
    tls internal
    reverse_proxy seaweed-mini:23646
}

${SWFS_FILER_FQDN}:8888, https://${HOST_IP}:8888 {
    tls internal
    handle /seaweedfsstatic/* {
        reverse_proxy seaweed-mini:8888
    }
    handle /${FILER_DIR}* {
        basic_auth {
            ${SWFS_USER} ${CADDY_HASHED_PASSWORD}
        }
        reverse_proxy seaweed-mini:8888
    }
}

${SWFS_MASTER_FQDN}:9333, https://${HOST_IP}:9333 {
    tls internal
    basic_auth {
        ${SWFS_USER} ${CADDY_HASHED_PASSWORD}
    }
    reverse_proxy seaweed-mini:9333
}

${SWFS_S3_FQDN}:8333, https://${HOST_IP}:8333 {
    tls internal
    reverse_proxy seaweed-mini:8333
}
EOF
```

---

## 5. Create the Docker Compose File

```bash
sudo tee /opt/seaweedfs/seaweedfs-compose.yaml > /dev/null <<EOF
networks:
  seaweed_net:
    name: seaweed_net

services:
  seaweed-mini:
    image: chrislusf/seaweedfs:latest
    container_name: seaweed-mini
    environment:
      - AWS_ACCESS_KEY_ID=${SWFS_USER}
      - AWS_SECRET_ACCESS_KEY=${SWFS_PASSWORD}
    command: >
      mini
      -admin.user "${SWFS_USER}"
      -admin.password "${SWFS_PASSWORD}"
      -dir=/data
      -webdav=false
    volumes:
      - /opt/seaweedfs/mini:/data
    networks:
      - seaweed_net
    restart: unless-stopped

  caddy:
    image: caddy:latest
    container_name: seaweed-caddy
    ports:
      - "443:443"
      - "9333:9333"
      - "8888:8888"
      - "8333:8333"
    volumes:
      - /opt/caddy/Caddyfile:/etc/caddy/Caddyfile
    networks:
      - seaweed_net
    restart: unless-stopped
    depends_on:
      - seaweed-mini
EOF
```

---

## 6. Start the Core Stack

```bash
sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d
```

Watch logs until both containers are healthy:

```bash
sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml logs -f
```

Press `Ctrl+C` to exit log tailing.

---

## 7. Configure S3 Access

Wait for the SeaweedFS Filer to be ready (returns HTTP 2xx), then create the default filer directory, configure S3 credentials, and create the default bucket.

```bash
# Wait for Filer to become ready
until docker exec seaweed-mini curl -so /dev/null -w '%{http_code}' http://localhost:8888 | grep -q '^2'; do
  echo "Waiting for Filer..."; sleep 5
done

# Create the default filer directory
docker exec seaweed-mini curl -X POST http://localhost:8888/${FILER_DIR}/

# Configure S3 credentials
echo "s3.configure -access_key=${S3_ACCESS_KEY} -secret_key=${S3_SECRET_KEY} -user=${S3_USER} -actions=Read,Write,List,Admin -apply=true" \
  | docker exec -i seaweed-mini /usr/bin/weed shell

# Create the default S3 bucket
echo "s3.bucket.create -name ${S3_BUCKET} -owner=${S3_USER}" \
  | docker exec -i seaweed-mini /usr/bin/weed shell
```

Save your credentials for later use:

```bash
echo "
=== SeaweedFS Install Summary ===
Admin UI:     https://${HOST_IP}:443
Master UI:    https://${HOST_IP}:9333
Filer:        https://${HOST_IP}:8888/${FILER_DIR}
S3 Endpoint:  https://${HOST_IP}:8333

Web UI credentials:
  Username:   ${SWFS_USER}
  Password:   ${SWFS_PASSWORD}

S3 credentials:
  User:       ${S3_USER}
  Bucket:     ${S3_BUCKET}
  Access Key: ${S3_ACCESS_KEY}
  Secret Key: ${S3_SECRET_KEY}
"
```

To retrieve the Caddy root CA certificate (for trusting the self-signed cert in browsers or tools):

```bash
docker exec seaweed-caddy cat /data/caddy/pki/authorities/local/root.crt > seaweedfs-root-ca.crt
```

---
---

## Optional: SeaweedMQ Message Broker

Append the `seaweed-mq` service to the existing compose file, then restart the stack.

```bash
sudo tee -a /opt/seaweedfs/seaweedfs-compose.yaml > /dev/null <<EOF

  seaweed-mq:
    image: chrislusf/seaweedfs:latest
    container_name: seaweed-mq
    command: >
      mq.broker
      -port=17777
      -master=seaweed-mini:9333
    ports:
      - "17777:17777"
    networks:
      - seaweed_net
    restart: unless-stopped
EOF

sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d
```

---

## Optional: SMB File Share

SeaweedFS is FUSE-mounted to the host at `/mnt/seaweed`, then Samba shares it over SMB with basic authentication.

### 1. Install Samba

**Ubuntu 22.04 / 24.04:**
```bash
sudo apt-get update && sudo apt-get install -y samba
```

**RHEL 9.x:**
```bash
sudo dnf install -y samba
```

**SLES 15 / 16:**
```bash
sudo zypper install -y samba
```

### 2. Add FUSE Mount and Samba User

```bash
# Allow non-root FUSE mounts
sudo mkdir -p /mnt/seaweed
echo "user_allow_other" | sudo tee /etc/fuse.conf

# Create a system user for the SMB share
sudo useradd -M -s /sbin/nologin ${SWFS_USER}
(echo "${SWFS_PASSWORD}"; echo "${SWFS_PASSWORD}") | sudo smbpasswd -a -s ${SWFS_USER}
```

### 3. Configure Samba

```bash
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

sudo tee -a /etc/samba/smb.conf > /dev/null <<EOF

[${FILER_DIR}]
   comment = SeaweedFS FUSE Mount
   path = /mnt/seaweed
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SWFS_USER}
   create mask = 0664
   directory mask = 0775

   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba

   force user = root
   force group = root
EOF
```

### 4. Add FUSE Mount Container to Compose

```bash
sudo tee -a /opt/seaweedfs/seaweedfs-compose.yaml > /dev/null <<EOF

  seaweed-mount:
    image: chrislusf/seaweedfs:latest
    container_name: seaweed-mount
    privileged: true
    command:
      mount
      -filer=seaweed-mini:8888
      -filer.path=/${FILER_DIR}
    volumes:
      - "/mnt/seaweed:/data:z,shared"
      - "/etc/fuse.conf:/etc/fuse.conf:ro"
    restart: unless-stopped
    networks:
      - seaweed_net
EOF
```

### 5. Restart the Stack and Samba

```bash
sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d

# Ubuntu / Debian
sudo systemctl restart smbd

# RHEL / Rocky / SLES
sudo systemctl restart smb
```

**Mount from Windows:**
```
net use Z: \\<HOST_IP>\artifacts <SWFS_PASSWORD> /USER:<SWFS_USER> /PERSISTENT:YES
```

---

## Optional: NFS Export

NFS shares the same FUSE mount at `/mnt/seaweed` over NFSv3 with no authentication.

> **Note:** If you already added the `seaweed-mount` container for SMB, skip steps 1 and 3 — the FUSE mount container is shared.

### 1. Allow FUSE and Create Mount Point

```bash
sudo mkdir -p /mnt/seaweed
echo "user_allow_other" | sudo tee /etc/fuse.conf
```

### 2. Install NFS Server

**Ubuntu 22.04 / 24.04:**
```bash
sudo apt-get update && sudo apt-get install -y nfs-kernel-server
```

**RHEL 9.x:**
```bash
sudo dnf install -y nfs-utils
```

**SLES 15 / 16:**
```bash
sudo zypper install -y nfs-kernel-server
```

### 3. Add FUSE Mount Container to Compose (skip if already added for SMB)

```bash
sudo tee -a /opt/seaweedfs/seaweedfs-compose.yaml > /dev/null <<EOF

  seaweed-mount:
    image: chrislusf/seaweedfs:latest
    container_name: seaweed-mount
    privileged: true
    command:
      mount
      -filer=seaweed-mini:8888
      -filer.path=/${FILER_DIR}
    volumes:
      - "/mnt/seaweed:/data:z,shared"
      - "/etc/fuse.conf:/etc/fuse.conf:ro"
    restart: unless-stopped
    networks:
      - seaweed_net
EOF
```

### 4. Configure and Start NFS

```bash
echo "/mnt/seaweed *(rw,sync,no_subtree_check,no_root_squash,insecure) # seaweedfs-installer" \
  | sudo tee -a /etc/exports

sudo exportfs -ra

# Ubuntu / Debian
sudo systemctl enable --now nfs-kernel-server

# RHEL / Rocky / SLES
sudo systemctl enable --now nfs-server
```

### 5. Restart the Stack

```bash
sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d
```

**Mount from a Linux client:**
```bash
sudo mount -t nfs -o vers=3 <HOST_IP>:/mnt/seaweed /mnt/seaweed
```

---

## Optional: Monitoring Stack (Grafana, Loki, Prometheus)

> **Recommendation:** Only deploy the monitoring stack if you plan to use an external log or metrics collector — such as Fluent Bit or a Prometheus remote-write agent — to ship data to this host. If no external agents are configured, this stack adds unnecessary overhead.

The monitoring stack runs as a second Docker Compose project that attaches to the existing `seaweed_net` network. Loki stores logs in the SeaweedFS S3 bucket. Grafana is proxied through Caddy with TLS.

### Define Additional Variables

```bash
CLUSTER_NAME="edge-lab"
LOKI_BUCKET="loki-logs"
GRAFANA_FQDN="grafana.${HOST_FQDN}"
```

### 1. Create Directories

```bash
sudo mkdir -p /opt/monitoring/loki/data
sudo mkdir -p /opt/monitoring/prometheus/data
sudo mkdir -p /opt/monitoring/grafana/data
sudo mkdir -p /opt/monitoring/grafana/provisioning/datasources
sudo chmod 777 /opt/monitoring/loki/data \
               /opt/monitoring/prometheus/data \
               /opt/monitoring/grafana/data
```

### 2. Create the Loki S3 Bucket

```bash
echo "s3.bucket.create -name ${LOKI_BUCKET} -owner=${S3_USER}" \
  | docker exec -i seaweed-mini /usr/bin/weed shell
```

### 3. Write Loki Configuration

```bash
sudo tee /opt/monitoring/loki/loki-config.yaml > /dev/null <<EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: "2024-01-01"
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: loki_index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/index_cache
  aws:
    endpoint: http://seaweed-mini:8333
    bucketnames: ${LOKI_BUCKET}
    access_key_id: ${S3_ACCESS_KEY}
    secret_access_key: ${S3_SECRET_KEY}
    s3forcepathstyle: true
    insecure: true

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: s3

limits_config:
  retention_period: 30d
  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32
  max_query_parallelism: 32
  max_query_series: 5000

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100
EOF
```

### 4. Write Prometheus Configuration

```bash
sudo tee /opt/monitoring/prometheus/prometheus.yml > /dev/null <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: ${CLUSTER_NAME}

scrape_configs:
  - job_name: "prometheus-self"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "loki"
    static_configs:
      - targets: ["loki:3100"]

  - job_name: "grafana"
    static_configs:
      - targets: ["grafana:3000"]
EOF
```

### 5. Write Grafana Datasources

```bash
sudo tee /opt/monitoring/grafana/provisioning/datasources/datasources.yaml > /dev/null <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
    jsonData:
      maxLines: 1000
EOF
```

### 6. Add Grafana to the Caddyfile

Append a Grafana virtual host to `/opt/caddy/Caddyfile` and add port `3000` to the Caddy container.

```bash
sudo tee -a /opt/caddy/Caddyfile > /dev/null <<EOF

${GRAFANA_FQDN}:3000, https://${HOST_IP}:3000 {
    tls internal
    reverse_proxy grafana:3000
}
EOF
```

Add port `3000` to the caddy service in the compose file:

```bash
sudo sed -i '/- "8333:8333"/a\      - "3000:3000"' /opt/seaweedfs/seaweedfs-compose.yaml
```

Reload Caddy:

```bash
sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d --force-recreate caddy
```

### 7. Write the Monitoring Compose File

```bash
sudo tee /opt/monitoring/docker-compose.yml > /dev/null <<EOF
networks:
  seaweed_net:
    external: true
    name: seaweed_net

services:
  loki:
    image: grafana/loki:3.4.2
    container_name: loki
    restart: unless-stopped
    ports:
      - "3100:3100"
    volumes:
      - /opt/monitoring/loki/loki-config.yaml:/etc/loki/local-config.yaml:ro
      - /opt/monitoring/loki/data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    networks:
      - seaweed_net
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --output-document=- http://localhost:3100/ready || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5

  prometheus:
    image: prom/prometheus:v3.2.1
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - /opt/monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /opt/monitoring/prometheus/data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=90d"
      - "--web.enable-remote-write-receiver"
      - "--web.enable-lifecycle"
    networks:
      - seaweed_net
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --output-document=- http://localhost:9090/-/healthy || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5

  grafana:
    image: grafana/grafana-oss:11.5.2
    container_name: grafana
    restart: unless-stopped
    environment:
      - GF_SECURITY_ADMIN_USER=${SWFS_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${SWFS_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - /opt/monitoring/grafana/data:/var/lib/grafana
      - /opt/monitoring/grafana/provisioning/datasources/datasources.yaml:/etc/grafana/provisioning/datasources/datasources.yaml:ro
    networks:
      - seaweed_net
    depends_on:
      loki:
        condition: service_healthy
      prometheus:
        condition: service_healthy
EOF
```

### 8. Start the Monitoring Stack

```bash
sudo docker compose -f /opt/monitoring/docker-compose.yml up -d
```

Check that Loki becomes healthy before sending logs:

```bash
until docker exec loki wget -qO- http://localhost:3100/ready 2>/dev/null | grep -q "ready"; do
  echo "Waiting for Loki..."; sleep 10
done
echo "Monitoring stack is ready."
```

Save the monitoring credentials for use by external agents:

```bash
sudo tee /opt/seaweedfs/monitoring-credentials.env > /dev/null <<EOF
MONITORING_HOST=${HOST_IP}
MONITORING_S3_ACCESS_KEY=${S3_ACCESS_KEY}
MONITORING_S3_SECRET_KEY=${S3_SECRET_KEY}
MONITORING_S3_ENDPOINT=http://${HOST_IP}:8333
MONITORING_LOKI_BUCKET=${LOKI_BUCKET}
MONITORING_LOKI_PORT=3100
MONITORING_PROMETHEUS_PORT=9090
CLUSTER_NAME=${CLUSTER_NAME}
EOF
sudo chmod 600 /opt/seaweedfs/monitoring-credentials.env
```

**Monitoring endpoints:**

| Service | URL | Auth |
|:--------|:----|:-----|
| Grafana | `https://${HOST_IP}:3000` | `${SWFS_USER}` / `${SWFS_PASSWORD}` |
| Loki | `http://${HOST_IP}:3100` | None |
| Prometheus | `http://${HOST_IP}:9090` | None |

---
---

## Offline Preparation

Run these steps on an **internet-connected** machine to build an archive, then transfer it to the air-gapped target.

### Pull and Save Docker Images

```bash
# Core images
docker pull chrislusf/seaweedfs:latest
docker pull caddy:latest

# Monitoring images (skip if not deploying monitoring)
docker pull grafana/loki:3.4.2
docker pull grafana/grafana-oss:11.5.2
docker pull prom/prometheus:v3.2.1

# Save core images
docker save chrislusf/seaweedfs:latest caddy:latest \
  | gzip > seaweedfs-images.tar.gz

# Save core + monitoring images
docker save \
  chrislusf/seaweedfs:latest \
  caddy:latest \
  grafana/loki:3.4.2 \
  grafana/grafana-oss:11.5.2 \
  prom/prometheus:v3.2.1 \
  | gzip > seaweedfs-images-full.tar.gz
```

### Save OS Packages

> Run this on a machine with the same OS version as the target.

**Ubuntu 22.04 / 24.04:**
```bash
sudo apt-get install --download-only samba nfs-kernel-server
tar czf packages-ubuntu.tar.gz -C /var/cache/apt/archives/ .
```

**RHEL 9.x:**
```bash
sudo dnf download --resolve --destdir=/tmp/pkg samba nfs-utils
tar czf packages-rhel.tar.gz -C /tmp/pkg .
```

**SLES 15 / 16:**
```bash
sudo zypper install --download-only samba nfs-kernel-server
sudo tar czf packages-sles.tar.gz -C /var/cache/zypp/packages/ .
```

### Transfer Files to the Air-Gapped Host

Copy the following to the target machine (USB, SCP to a jump host, etc.):
- `seaweedfs-images.tar.gz` (or `seaweedfs-images-full.tar.gz`)
- `packages-<os>.tar.gz`

### Load Docker Images on the Target

```bash
docker load < seaweedfs-images.tar.gz
```

Verify images are loaded:

```bash
docker images | grep -E 'seaweedfs|caddy|loki|grafana|prometheus'
```

### Install OS Packages on the Target

**Ubuntu 22.04 / 24.04:**
```bash
mkdir -p /tmp/pkg && tar xzf packages-ubuntu.tar.gz -C /tmp/pkg/
sudo dpkg -i /tmp/pkg/*.deb
```

**RHEL 9.x:**
```bash
mkdir -p /tmp/pkg && tar xzf packages-rhel.tar.gz -C /tmp/pkg/
sudo dnf install /tmp/pkg/*.rpm
```

**SLES 15 / 16:**
```bash
mkdir -p /tmp/pkg && tar xzf packages-sles.tar.gz -C /tmp/pkg/
sudo rpm -ivh /tmp/pkg/*.rpm
```

After loading images and packages, follow the core installation steps from [Section 1](#1-define-your-variables) onward. The `docker pull` steps will be skipped since images are already present locally.

---
---

## Local Registry

Use these steps when deploying with a local container registry (e.g. Harbor, Nexus, or a plain Docker registry).

### Define Registry Variables

```bash
REG_HOST="myregistry.example.com"
REG_PORT="5000"
REG_USER="reguser"
REG_PASS="regpassword"
```

### Retrieve the Registry TLS Certificate

```bash
sudo mkdir -p /etc/docker/certs.d/${REG_HOST}:${REG_PORT}

openssl s_client -connect ${REG_HOST}:${REG_PORT} -showcerts \
  </dev/null 2>/dev/null \
  | openssl x509 -outform PEM \
  | sudo tee /etc/docker/certs.d/${REG_HOST}:${REG_PORT}/ca.crt

sudo systemctl restart docker
```

### Log In to the Registry

```bash
docker login ${REG_HOST}:${REG_PORT} -u "${REG_USER}" -p "${REG_PASS}"
```

### Tag and Push Images

The registry must have these projects pre-created before pushing. See the [README](README.md#push-option) for the required project list.

```bash
# SeaweedFS
docker tag chrislusf/seaweedfs:latest ${REG_HOST}:${REG_PORT}/chrislusf/seaweedfs:latest
docker push ${REG_HOST}:${REG_PORT}/chrislusf/seaweedfs:latest

# Caddy (uses the 'library' project namespace)
docker tag caddy:latest ${REG_HOST}:${REG_PORT}/library/caddy:latest
docker push ${REG_HOST}:${REG_PORT}/library/caddy:latest

# Monitoring images (skip if not deploying monitoring)
docker tag grafana/loki:3.4.2 ${REG_HOST}:${REG_PORT}/grafana/loki:3.4.2
docker push ${REG_HOST}:${REG_PORT}/grafana/loki:3.4.2

docker tag grafana/grafana-oss:11.5.2 ${REG_HOST}:${REG_PORT}/grafana/grafana-oss:11.5.2
docker push ${REG_HOST}:${REG_PORT}/grafana/grafana-oss:11.5.2

docker tag prom/prometheus:v3.2.1 ${REG_HOST}:${REG_PORT}/prom/prometheus:v3.2.1
docker push ${REG_HOST}:${REG_PORT}/prom/prometheus:v3.2.1
```

### Deploy Using Registry Images

When creating the Docker Compose and monitoring compose files, substitute the image names with the registry-prefixed versions:

```bash
# Override image variables before following the core install steps
SWFS_IMAGE="${REG_HOST}:${REG_PORT}/chrislusf/seaweedfs:latest"
CADDY_IMAGE="${REG_HOST}:${REG_PORT}/library/caddy:latest"
LOKI_IMAGE="${REG_HOST}:${REG_PORT}/grafana/loki:3.4.2"
GRAFANA_IMAGE="${REG_HOST}:${REG_PORT}/grafana/grafana-oss:11.5.2"
PROMETHEUS_IMAGE="${REG_HOST}:${REG_PORT}/prom/prometheus:v3.2.1"
```

Then proceed with [Section 5 (Create the Docker Compose File)](#5-create-the-docker-compose-file) and replace `chrislusf/seaweedfs:latest` / `caddy:latest` with `${SWFS_IMAGE}` / `${CADDY_IMAGE}`, and similarly for the monitoring compose file.
