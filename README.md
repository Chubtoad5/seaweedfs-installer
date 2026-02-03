# SeaweedFS Installer

This helper script installs SeaweedFS 'mini' in a docker environment for a secure and simple file storage solution. A Caddy sidecar container is used to provide reverse proxy, TLS, basic authentication, and a simple landing page.

# Features

- Automates pre-requisites, including installing docker runtime based on detected OS release
- SeaweedFS container using 'weed mini' installs Admin UI, Master, Volume, Filer, S3, and SMB Share (optional)
- Caddy container serves a reverse proxy, using self-signed TLS, basic authentication, and a web server landing page
- Supports creating an offline archive for air-gapped environments, including docker binaries and container images for the detected OS release
- Automatically detects air-gapped mode when a valid ```swfs-save.tar.gz``` is present
- Supports pushing container images to a local registry and using local registry for pulling images at runtime
- Supports automatic download of user defined binaries and uploading them to the default Filer path

# Usage

## Quick installation
```
git clone https://github.com/Chubtoad5/seaweedfs-installer.git
cd seaweedfs-installer
chmod +x seaweedfs-installer
sudo ./seaweedfs-installer install
```

## General Usage
```
Usage: ./install-seaweedfs [command] [option]

Commands:
  help        | Display this help message
  install     | Install and configure SeaweedFS and Caddy (Docker Compose)
  save        | Prepare offline archive for air-gapped deployment
  uninstall   | Uninstall SeaweedFS and Caddy including data and configuration

Options:
  push        | Push SeaweedFS and Caddy images to a local registry, must include -registry option
  -registry   | Registry credentials for pushing or pulling from local registry (Format: -registry [registry:port username password])

Examples:
  ./install-seaweedfs install
  ./install-seaweedfs save
  ./install-seaweedfs uninstall
  ./install-seaweedfs install -registry myregistry:5000 user password
  ./install-seaweedfs install push -registry myregistry:5000 user password
  ```

## Command and Option Information

### Install

Installs Docker runtime, SeaweedFS container, and Caddy container from the internet. If a valid ```swfs-save.tar.gz``` is in the same directory as ```install-seaweedfs```, air-gapped install will occur. If ```-registry``` is used, script will attempt to pull containers from a local registry.  
SeaweedFS configuration files, including docker compose yaml are located in ```/opt/seaweedfs```. All SeaweedFS user data is located in ```/opt/seaweedfs/mini```.  
Caddy configuration files are located in ```/opt/caddy```.  

### Save

Creates an offline archive to use for air-gapped environments that includes docker binaries, SeaweedFS container, and Caddy container. To use the offline archive, extract it with ```tar xzf swfs-save.tar.gz``` then run the script as normal. The ```swfs-save.tar.gz``` must be in the same directory as ```seaweedfs-installer``` file.

### Uninstall

Stops and removes containers, then deletes the container configuration directories. Uninstall is destructuve and will delete all SeaweedFS user data.

### Push

First pulls containers from the internet or loads them locally from archive when a valid ```swfs-save.tar.gz``` is detected, then pushes the containers to the specified registry. The registry must have the ```/chrislufs``` and ```/library``` projects pre-created in order to push the containers.

### Registry

When specified, will attempt to obtain the registry TLS certificate and login via docker in order to push and/or pull containers.

# Custom Variables

Edit the ```install-seaweedfs``` file and view the ```USER DEFINED VARIABLES``` section to modify the default behavior of the script.  
All user defined variables support being passed through from frontend shell, for example:  
```
sudo SWFS_USER="weeduser" SWFS_PASSWORD="weedpassword" ./install-seaweedfs install
```

## User Defined Variables
|Variable              |Default Value              |Definition                                     |
|:---------------------|---------------------------|:----------------------------------------------|
|DEBUG                 |1                          |When disabled (0), script runs in silent mode  |
|SWFS_IMAGE            |chrislusf/seaweedfs:latest |Project/image:tag for SeaweedFS                |
|CADDY_IMAGE           |caddy:latest               |Project/image:tag for Caddy (defaults /library)|
|SWFS_USER             |admin                      |Username for Admin UI and Caddy basic auth     |
|SWFS_PASSWORD         |changeme                   |Password for Admin UI and Caddy basic auth     |
|HOST_FQDN             |$(hostanme).edge.lab       |FQDN for the host, i.e. myhost.mydomain.com    |
|SWFS_ADMIN_FQDN       |admin.$HOST_FQDN           |FQDN prefix for Admin UI                       |
|SWFS_MASTER_FQDN      |master.$HOST_FQDN          |FQDN prefix for Master service                 |
|SWFS_FILER_FQDN       |filer.$HOST_FQDN           |FQDN prefix for Filer service                  |
|SWFS_S3_FQDN          |s3.$HOST_FQDN              |FQDN prefix for S3 endpoint service            |
|MGMT_IP               |$(hostname -I)             |Host's IP to use when DNS not configured       |
|SWFS_ADMIN_PORT       |443                        |TCP port for Admin UI                          |
|SWFS_MASTER_PORT      |9333                       |TCP port for Master service                    |
|SWFS_FILER_PORT       |8888                       |TCP port for Filer service                     |
|SWFS_S3_PORT          |8333                       |TCP port for S3 endpoint                       |
|S3_BUCKET             |charlie                    |Default S3 bucket name                         |
|S3_USER               |$SWFS_USER                 |Default S3 API user name                       |
|S3_ACCESS_KEY         |openssl rand -hex 8        |Default S3 access key (randomly generated)     |
|S3_SECRET_KEY         |openssl rand -hex 16       |Default S3 secret key (randomly generated)     |
|DEFAULT_FILER_DIR_NAME|artifacts                  |Default path for filer user data               |
|ENABLE_SMB            |true                       |Enables SMB with basic auth on default filter path|
|ARTIFACTS_TO_DOWNLOAD |""                         |List of space separated binary URLs for filer upload. Example: "https://static/file1.txt https://static/image1.img" |

## Known Issues

In rare occurances, the `seaweed-mount` container may fail to start with the following error:  
```
Error response from daemon: invalid mount config for type "bind": stat /mnt/seaweed: transport endpoint is not connected
```  
This error may occur when the host fuse process becomes hung due to unexpected conflict (i.e. docker or system crash, OOM, etc.). Follow these steps to resolve the issue.  

1. Verify mount point is hung:
```
ls -al /mnt/seaweed
ls -al /mnt/
```
Typicaly you see message like `ls: cannot access '/mnt/seaweed': Transport endpoint is not connected`  
Or a strange directory listing `d?????????  ? ?    ?       ?            ? seaweed`  

2. Identify the hung mount point and process (if any):

```
mount | grep /mnt/seaweed || true
findmnt -T /mnt/seaweed -o TARGET,SOURCE,FSTYPE,OPTIONS || true
ps aux | egrep 'weed.*mount|seaweed|fuse' | grep -v egrep
lsof +D /mnt/seaweed 2>/dev/null | head
```

3. Unmount the hung device:
```
sudo umount -l /mnt/seaweed
```

4. Verify directory listing comes back normal:
```
 ls -al /mnt/seaweed
 ls -al /mnt/
 ```

 5. Start docker compose again:

 ```
sudo docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d
 ```