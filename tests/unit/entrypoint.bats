#!/usr/bin/env bats
# S17: seaweed-mini starts through the installer's entrypoint, which passes the admin password whole. S18: /opt/seaweedfs
# is root-only, so mini.options stays private. These write under /opt and /etc, so they run only as root in a container,
# as CI's unit tier does.
load ../helpers

setup() {
  [[ $EUID -eq 0 && ( -f /run/.containerenv || -f /.dockerenv ) ]] || skip "writes under /opt and /etc: root in a container only"
  setup_stubs
  load_script install-seaweedfs
  T=$(mktemp -d)
  LOG_FILE=$T/install.log
  rm -rf /opt/seaweedfs
  SWFS_USER=admin SWFS_PASSWORD='Test Pass*?[1' DEFAULT_FILER_DIR_NAME=artifacts ENABLE_MONITORING=false
  ENABLE_MQ=false ENABLE_SMB=false ENABLE_NFS=false CLUSTER_MODE=single
  configure_fuse_conf() { :; }
}
teardown() { rm -rf /opt/seaweedfs; }

# service_block <service>: that service's lines in the compose file
service_block() { awk -v s="  $1:" '$0 == s {on = 1; print; next} on && /^  [a-z]/ {exit} on' /opt/seaweedfs/seaweedfs-compose.yaml; }

# run_entrypoint <args...>: the written entrypoint under sh, with weed replaced by a stub that prints what it got
run_entrypoint() {
  sed "s#/usr/bin/weed#$STUB_DIR/weed#g" /opt/seaweedfs/weed-entrypoint.sh > "$T/entrypoint.sh"
  stub weed 'echo "GODEBUG=$GODEBUG"; printf "<%s>\n" "$@"'
  (cd "$T" && sh "$T/entrypoint.sh" "$@")
}

@test "S17: seaweed-mini starts through the installer's entrypoint, mounted read-only" {
  private_dir /opt/seaweedfs
  generate_compose_file
  block=$(service_block seaweed-mini)
  [[ "$block" == *'entrypoint: ["/bin/sh", "/weed-entrypoint.sh"]'* ]]
  [[ "$block" == *'- /opt/seaweedfs/weed-entrypoint.sh:/weed-entrypoint.sh:ro'* ]]
  [ "$(stat -c %a /opt/seaweedfs/weed-entrypoint.sh)" = 644 ]
  # the compose command still carries the password quoted, for compose's own split
  [[ "$block" == *'-admin.password "Test Pass*?[1"'* ]]
}

@test "S17: only seaweed-mini gets it; MQ, the mount and a volume node keep the image's" {
  ENABLE_MQ=true ENABLE_SMB=true
  private_dir /opt/seaweedfs
  generate_compose_file
  [ "$(grep -c 'entrypoint:' /opt/seaweedfs/seaweedfs-compose.yaml)" = 1 ]
  [[ "$(service_block seaweed-mq)" != *entrypoint* ]]
  [[ "$(service_block seaweed-mount)" != *entrypoint* ]]
  CLUSTER_MASTER=10.0.0.1:19333 MGMT_IP=10.0.0.2 CLUSTER_DC=dc1 CLUSTER_RACK=rack1
  record_state() { :; }
  generate_join_compose_file
  ! grep -q 'entrypoint:' /opt/seaweedfs/seaweedfs-volume-compose.yaml
}

@test "S17: the entrypoint passes a password with a space, *, ? and [ as one argument, unglobbed" {
  private_dir /opt/seaweedfs
  write_weed_entrypoint
  touch "$T/Test-glob-bait" "$T/x1"
  run run_entrypoint mini -admin.user admin -admin.password 'Test Pass*?[1' -dir=/data 'x?'
  [ "$status" -eq 0 ]
  # not root with su-exec here, or no seaweed user: weed is run directly, as the image's own entrypoint does then
  [ "${lines[0]}" = "GODEBUG=fips140=on" ]
  [ "${lines[1]}" = "<-logtostderr=true>" ]
  [ "${lines[2]}" = "<mini>" ]
  [ "${lines[6]}" = "<Test Pass*?[1>" ]
  [ "${lines[8]}" = "<x?>" ]
  [ "${#lines[@]}" -eq 9 ]
}

@test "S17: as root, it gives /data to the seaweed user when it isn't theirs, and runs weed as that user" {
  private_dir /opt/seaweedfs
  write_weed_entrypoint
  stub id 'case "$1" in -u) [ -n "$2" ] && echo 1000 || echo 0 ;; -g) echo 1000 ;; seaweed) exit 0 ;; esac'
  stub su-exec 'shift; exec "$@"'
  stub chown
  stub stat 'echo 0:0'
  run run_entrypoint mini -admin.password 'a b'
  [ "$status" -eq 0 ]
  called "chown -R seaweed:seaweed /data"
  called "su-exec seaweed $STUB_DIR/weed -logtostderr=true mini -admin.password a b"
  [[ "$output" == *"<a b>"* ]]
  # already theirs: no chown
  : > "$STUB_LOG"
  stub stat 'echo 1000:1000'
  run run_entrypoint mini
  [ "$status" -eq 0 ]
  ! called "chown"
  called "su-exec seaweed"
}

@test "S18: install and join make /opt/seaweedfs root-only, before anything is written there" {
  first_step() { declare -f "$1" | sed -n '3,4p' | sed 's/^ *//; s/;$//' | tr '\n' '|'; }
  [[ "$(first_step install_swfs)" == *'private_dir /opt/seaweedfs'* ]]
  [[ "$(first_step run_join)" == *'private_dir /opt/seaweedfs'* ]]
  mkdir -p /opt/seaweedfs; chmod 755 /opt/seaweedfs
  private_dir /opt/seaweedfs
  [ "$(stat -c %a /opt/seaweedfs)" = 700 ]
}
