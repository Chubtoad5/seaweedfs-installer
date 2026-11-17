#!/usr/bin/env bats
# Spec 24: the SeaweedFS image pin (S30), and the Admin UI on port 12535 with every image (S31). weed 4.49 moved the
# Admin UI's default port from 23646 to 12535, so mini gets -admin.port and Caddy proxies there; a 4.30 image (still
# passed by object-tech-ops) serves the same port. Tests that write under /opt run only as root in a container.
load ../helpers

setup() {
  setup_stubs
  load_script install-seaweedfs
  T=$(mktemp -d)
  LOG_FILE=$T/install.log STATE_FILE=$T/state
  stub sleep
}

in_container() {
  [[ $EUID -eq 0 && ( -f /run/.containerenv || -f /.dockerenv ) ]] || skip "writes under /opt: root in a container only"
}

# mini_command: seaweed-mini's command list, one item per line, as compose would see it
mini_command() { python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); [print(a.replace("$$", "$")) for a in d["services"]["seaweed-mini"]["command"]]' /opt/seaweedfs/seaweedfs-compose.yaml; }

compose_setup() {
  in_container
  rm -rf /opt/seaweedfs
  SWFS_USER=admin SWFS_PASSWORD=changeme DEFAULT_FILER_DIR_NAME=artifacts ENABLE_MONITORING=false ENABLE_MQ=false
  ENABLE_SMB=false ENABLE_NFS=false PUSH_MODE=0 REGISTRY_MODE=0 MGMT_IP=10.0.0.5
  configure_fuse_conf() { :; }
  record_state() { :; }
  private_dir /opt/seaweedfs
}

@test "S30: the default image is chrislusf/seaweedfs:4.54" {
  grep -qxF 'SWFS_IMAGE=${SWFS_IMAGE:-"chrislusf/seaweedfs:4.54"}' "$BATS_TEST_DIRNAME/../../install-seaweedfs"
}

@test "S30: an SWFS_IMAGE set by the caller, such as object-tech-ops' 4.30, wins over the default" {
  SWFS_IMAGE=chrislusf/seaweedfs:4.30
  eval "$(grep -m1 '^SWFS_IMAGE=' "$BATS_TEST_DIRNAME/../../install-seaweedfs")"
  [ "$SWFS_IMAGE" = chrislusf/seaweedfs:4.30 ]
  SWFS_IMAGE=""
  eval "$(grep -m1 '^SWFS_IMAGE=' "$BATS_TEST_DIRNAME/../../install-seaweedfs")"
  [ "$SWFS_IMAGE" = chrislusf/seaweedfs:4.54 ]
}

@test "S31: seaweed-mini gets -admin.port=12535, once, in single-node mode" {
  compose_setup
  CLUSTER_MODE=single
  generate_compose_file
  [ "$(mini_command | grep -c -- '^-admin\.port')" = 1 ]
  mini_command | grep -qxF -- '-admin.port=12535'
}

@test "S31: seaweed-mini gets -admin.port=12535 in cluster mode too" {
  compose_setup
  CLUSTER_MODE=cluster CLUSTER_DC=dc1 CLUSTER_RACK=r1 CLUSTER_MASTER_GRPC_PORT=19333 CLUSTER_VOLUME_PORT=9340
  CLUSTER_VOLUME_GRPC_PORT=19340
  generate_compose_file
  [ "$(mini_command | grep -c -- '^-admin\.port')" = 1 ]
  mini_command | grep -qxF -- '-admin.port=12535'
}

@test "S31: no -admin.port.legacy flag, which a 4.30 image would refuse to start on" {
  compose_setup
  CLUSTER_MODE=single
  generate_compose_file
  ! mini_command | grep -q -- '-admin\.port\.legacy'
}

@test "S31: the 12535 port isn't published on the host" {
  compose_setup
  CLUSTER_MODE=cluster CLUSTER_DC=dc1 CLUSTER_RACK=r1 CLUSTER_MASTER_GRPC_PORT=19333 CLUSTER_VOLUME_PORT=9340
  CLUSTER_VOLUME_GRPC_PORT=19340
  generate_compose_file
  ! grep -q '12535\|22535' <(grep -v -- "- '-admin.port=12535'" /opt/seaweedfs/seaweedfs-compose.yaml)
}

@test "S31: all three Caddy upstreams to the Admin UI use seaweed-mini:12535, with the login gate on and off" {
  in_container
  stub docker 'case "$*" in
    *hash-password*) cat >/dev/null; echo "\$argon2id\$v=19\$m=1,t=1,p=1\$c2FsdA\$hash" ;;
    *validate*) exit 0 ;;
  esac'
  rm -rf /opt/caddy
  SWFS_PASSWORD=pw1 MGMT_IP=10.0.0.5 SPLASH_REQUIRE_LOGIN=true
  generate_caddyfile
  [ "$(grep -c 'seaweed-mini:12535 {' /opt/caddy/Caddyfile)" = 3 ]
  grep -qF 'forward_auth seaweed-mini:12535 {' /opt/caddy/Caddyfile
  ! grep -q 'seaweed-mini:23646' /opt/caddy/Caddyfile
  SPLASH_REQUIRE_LOGIN=false
  generate_caddyfile
  [ "$(grep -c 'reverse_proxy seaweed-mini:12535 {' /opt/caddy/Caddyfile)" = 2 ]
  ! grep -q 'forward_auth' /opt/caddy/Caddyfile
  rm -rf /opt/caddy
}

@test "S31: nothing in the installer or the manual proxies to the old port 23646" {
  ! grep -n 'seaweed-mini:23646' "$BATS_TEST_DIRNAME/../../install-seaweedfs" "$BATS_TEST_DIRNAME/../../swfs-manual.md"
}

# --- S37: cluster mode makes mini a one-member raft master, which 4.51+ needs to admit joined volume nodes ---

@test "S37: cluster mode gives mini -master.peers with its own address, once" {
  compose_setup
  CLUSTER_MODE=cluster CLUSTER_DC=dc1 CLUSTER_RACK=r1 CLUSTER_MASTER_GRPC_PORT=19333 CLUSTER_VOLUME_PORT=9340
  CLUSTER_VOLUME_GRPC_PORT=19340
  generate_compose_file
  [ "$(mini_command | grep -c -- '^-master\.peers')" = 1 ]
  mini_command | grep -qxF -- '-master.peers=10.0.0.5:9333'
}

@test "S37: a single-node install has no -master.peers, so its compose file is unchanged" {
  compose_setup
  CLUSTER_MODE=single
  generate_compose_file
  ! mini_command | grep -q -- '-master\.peers'
}

# --- S38: join checks that node 1's master admitted the volume server ---

@test "S38: a volume server the master lists is admitted" {
  MGMT_IP=192.0.2.20 CLUSTER_VOLUME_PORT=9340 CLUSTER_MASTER=192.0.2.10:9333
  stub docker 'cat > /dev/null; echo "  DataNode 192.0.2.10:9340 hdd(volume:1/8)"; echo "  DataNode 192.0.2.20:9340 hdd(volume:0/8)"'
  volume_admitted
  wait_for_admission
  called "exec -i seaweed-volume /usr/bin/weed shell -master=192.0.2.10:9333"
}

@test "S38: a volume server the master doesn't list isn't admitted, and the wait gives up" {
  MGMT_IP=192.0.2.20 CLUSTER_VOLUME_PORT=9340 CLUSTER_MASTER=192.0.2.10:9333
  stub docker 'cat > /dev/null; echo "  DataNode 192.0.2.10:9340 hdd(volume:1/8)"; echo "  DataNode 192.0.2.200:9340 hdd(volume:0/8)"'
  ! volume_admitted
  run wait_for_admission
  [ "$status" -ne 0 ]
  [ "$(grep -c 'weed shell' "$STUB_LOG")" -ge 18 ]
}

@test "S38: another port on the same address isn't this volume server" {
  MGMT_IP=192.0.2.20 CLUSTER_VOLUME_PORT=9340 CLUSTER_MASTER=192.0.2.10:9333
  stub docker 'cat > /dev/null; echo "  DataNode 192.0.2.20:9341 hdd(volume:0/8)"'
  ! volume_admitted
}

@test "S38: join waits for admission before it reports success, and fails without it" {
  body=$(declare -f run_join)
  [[ "$body" == *"wait_for_admission"*"die "*"generate_join_outputs"* ]]
}
