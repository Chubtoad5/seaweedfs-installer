#!/usr/bin/env bats
# S28 (spec 23): a dead /mnt/seaweed is cleared before Docker starts and before 'compose up', and Samba and NFS are
# re-exported once the new mount is up. These write under /usr/local/sbin, /etc/systemd and /run, so they run only as
# root in a container, as CI's unit tier does.
load ../helpers

setup() {
  [[ $EUID -eq 0 && ( -f /run/.containerenv || -f /.dockerenv ) ]] || skip "writes under /etc: root in a container only"
  REAL_STAT=$(command -v stat)
  setup_stubs
  load_script install-seaweedfs
  T=$(mktemp -d)
  STATE_FILE=$T/state LOG_FILE=$T/install.log SCRIPT_VERSION=9.9.9 SMB_SERVICE=smbd ENABLE_SMB=true ENABLE_NFS=true
  export T
  # The mount: findmnt reports $T/fstype, statfs answers when $T/statfs-ok exists, ps lists $T/ps.
  # umount takes the mount away (findmnt then reports nothing).
  echo fuse.seaweedfs > "$T/fstype"; touch "$T/statfs-ok"; : > "$T/ps"
  stub findmnt 'cat "$T/fstype"'
  stub stat '[[ "$1" == -f ]] && { [ -e "$T/statfs-ok" ]; exit; }; exec '"$REAL_STAT"' "$@"'
  stub ps 'cat "$T/ps"'
  stub timeout 'shift; "$@"'
  stub umount ': > "$T/fstype"'
  stub systemctl
  stub exportfs
  stub sleep
  # docker inspect: seaweed-mount runs when $T/running says true, and started at $T/started
  echo true > "$T/running"; date -u +%Y-%m-%dT%H:%M:%S.000000000Z > "$T/started"; echo false > "$T/live-restore"
  stub docker 'case "$*" in *LiveRestoreEnabled*) cat "$T/live-restore" ;; *State.Running*) cat "$T/running" ;; *State.StartedAt*) cat "$T/started" ;; esac; exit 0'
  # The guard does nothing on a host without SeaweedFS's compose file
  CREATED_COMPOSE=0
  [ -e /opt/seaweedfs/seaweedfs-compose.yaml ] || { mkdir -p /opt/seaweedfs; : > /opt/seaweedfs/seaweedfs-compose.yaml; CREATED_COMPOSE=1; }
  rm -f "$GUARD_BIN" "$GUARD_UNIT" "$GUARD_DROPIN" /run/seaweedfs-mount-guard
}
teardown() {
  rm -f "$GUARD_BIN" "$GUARD_UNIT" "$GUARD_DROPIN" /run/seaweedfs-mount-guard
  rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true
  [ "$CREATED_COMPOSE" = 1 ] && rm -f /opt/seaweedfs/seaweedfs-compose.yaml || true
}
dead() { rm -f "$T/statfs-ok"; }
weed_mount_running() { echo "/usr/bin/weed mount -filer=seaweed-mini:8888 -filer.path=/artifacts" > "$T/ps"; }

@test "S28: a live FUSE mount isn't dead" {
  ! swfs_mount_dead || false
}
@test "S28: a FUSE mount that fails statfs, with no weed mount process, is dead" {
  dead
  swfs_mount_dead
}
@test "S28: while this installer's weed mount process runs, the mount is never called dead" {
  dead; weed_mount_running
  ! swfs_mount_dead || false
}
@test "S28: another weed process (mini) doesn't count as the mount's daemon" {
  dead; echo "/usr/bin/weed -logtostderr=true mini -admin.user admin" > "$T/ps"
  swfs_mount_dead
}
@test "S28: a folder that isn't a FUSE mount is left alone" {
  echo ext4 > "$T/fstype"; dead
  ! swfs_mount_dead || false
  swfs_clear_dead_mount
  ! called umount || false
}
@test "S28: a dead mount is lazily unmounted, a live one isn't" {
  swfs_clear_dead_mount
  ! called umount || false
  dead
  run swfs_clear_dead_mount
  [ "$status" -eq 0 ]
  called "umount -l /mnt/seaweed"
  [[ "$output" == *"Cleared a dead FUSE mount at /mnt/seaweed"* ]]
}
@test "S28: install clears a dead mount before 'docker compose up', and uninstall removes the guard" {
  body=$(declare -f install_swfs)
  clear_at=$(grep -n 'swfs_clear_dead_mount' <<< "$body" | head -n 1 | cut -d: -f1)
  up_at=$(grep -n 'seaweedfs-compose.yaml up -d' <<< "$body" | head -n 1 | cut -d: -f1)
  [ -n "$clear_at" ] && [ -n "$up_at" ] && [ "$clear_at" -lt "$up_at" ]
  grep -q 'configure_mount_guard' <<< "$body"
  body=$(declare -f uninstall_swfs)
  grep -q 'remove_mount_guard' <<< "$body"
  grep -q 'swfs_clear_dead_mount' <<< "$body"
}
@test "S28: with SMB and NFS on, the guard, its unit and the Docker drop-in are written, and Docker isn't restarted" {
  run configure_mount_guard
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$GUARD_BIN")" = 755 ]
  bash -n "$GUARD_BIN"
  grep -qx 'SMB_SERVICE="smbd"' "$GUARD_BIN"
  grep -qx 'NFS_ON=1' "$GUARD_BIN"
  grep -q '^swfs_mount_dead ()' "$GUARD_BIN"
  grep -qx "ExecStartPre=-$GUARD_BIN clear" "$GUARD_DROPIN"
  grep -qx 'ExecStartPost=-/usr/bin/systemctl --no-block start seaweedfs-mount-guard.service' "$GUARD_DROPIN"
  grep -qx "ExecStart=$GUARD_BIN reexport" "$GUARD_UNIT"
  called "systemctl daemon-reload"
  ! called "systemctl restart docker" || false
  [[ "$output" == *"Docker wasn't restarted"* ]]
}
@test "S28: an unchanged guard isn't rewritten into a daemon-reload" {
  configure_mount_guard > /dev/null
  touch -d @1000000000 "$GUARD_BIN" "$GUARD_UNIT" "$GUARD_DROPIN"
  : > "$STUB_LOG"
  run configure_mount_guard
  [[ "$output" == *"no change"* ]]
  ! called "systemctl daemon-reload" || false
  # Not rewritten either: systemd would otherwise say docker.service's drop-ins changed on disk
  [ "$(stat -c %Y "$GUARD_DROPIN")" = 1000000000 ] && [ "$(stat -c %Y "$GUARD_BIN")" = 1000000000 ]
}
@test "S28: SMB only, or NFS only, sets the guard up for just that one" {
  ENABLE_NFS=false configure_mount_guard > /dev/null
  grep -qx 'SMB_SERVICE="smbd"' "$GUARD_BIN" && grep -qx 'NFS_ON=0' "$GUARD_BIN"
  ENABLE_SMB=false ENABLE_NFS=true configure_mount_guard > /dev/null
  grep -qx 'SMB_SERVICE=""' "$GUARD_BIN" && grep -qx 'NFS_ON=1' "$GUARD_BIN"
}
@test "S28: with SMB and NFS both off, the guard is removed" {
  configure_mount_guard > /dev/null
  [ -e "$GUARD_DROPIN" ]
  ENABLE_SMB=false ENABLE_NFS=false run configure_mount_guard
  [ "$status" -eq 0 ]
  [ ! -e "$GUARD_BIN" ] && [ ! -e "$GUARD_UNIT" ] && [ ! -e "$GUARD_DROPIN" ]
  [ ! -d /etc/systemd/system/docker.service.d ]
  [[ "$output" == *"removed"* ]]
}
@test "S28: turning SMB and NFS both off clears the mount compose has just stopped" {
  configure_mount_guard > /dev/null; dead; : > "$STUB_LOG"
  ENABLE_SMB=false ENABLE_NFS=false run configure_mount_guard
  [ "$status" -eq 0 ]
  called "umount -l /mnt/seaweed"
}
@test "S28: removing the guard keeps someone else's Docker drop-ins" {
  configure_mount_guard > /dev/null
  echo "[Service]" > /etc/systemd/system/docker.service.d/http-proxy.conf
  remove_mount_guard > /dev/null
  [ -e /etc/systemd/system/docker.service.d/http-proxy.conf ]
  rm -f /etc/systemd/system/docker.service.d/http-proxy.conf
}
@test "S28: the guard's clear records when this Docker start began, and unmounts a dead mount" {
  configure_mount_guard > /dev/null; dead; : > "$STUB_LOG"
  run "$GUARD_BIN" clear
  [ "$status" -eq 0 ]
  called "umount -l /mnt/seaweed"
  [[ "$(cat /run/seaweedfs-mount-guard)" =~ ^[0-9]+$ ]]
}
@test "S28: the guard's clear leaves a live mount alone" {
  configure_mount_guard > /dev/null; : > "$STUB_LOG"
  run "$GUARD_BIN" clear
  [ "$status" -eq 0 ]
  ! called umount || false
  [[ "$output" == *"is live, left alone"* ]]
}
@test "S28: when seaweed-mount kept running across the Docker start (live-restore), reexport leaves Samba and NFS alone" {
  configure_mount_guard > /dev/null; date +%s > /run/seaweedfs-mount-guard; echo 2020-01-01T00:00:00.000000000Z > "$T/started"
  echo true > "$T/live-restore"; : > "$STUB_LOG"
  run "$GUARD_BIN" reexport
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept running across the Docker start"* ]]
  ! called exportfs || false
  ! called "systemctl restart" || false
}
@test "S28: without live-restore, an earlier start time (a clock stepped back at boot) still re-exports" {
  configure_mount_guard > /dev/null; date +%s > /run/seaweedfs-mount-guard; echo 2020-01-01T00:00:00.000000000Z > "$T/started"; : > "$STUB_LOG"
  run "$GUARD_BIN" reexport
  [ "$status" -eq 0 ]
  called "exportfs -ra"
  called "systemctl restart smbd"
}
@test "S28: with live-restore, a start time that can't be read re-exports" {
  configure_mount_guard > /dev/null; date +%s > /run/seaweedfs-mount-guard; : > "$T/started"; echo true > "$T/live-restore"; : > "$STUB_LOG"
  run "$GUARD_BIN" reexport
  [ "$status" -eq 0 ]
  called "exportfs -ra"
}
@test "S28: a re-run gives the guard its execute bit back, without rewriting it" {
  configure_mount_guard > /dev/null
  chmod 644 "$GUARD_BIN"; touch -d @1000000000 "$GUARD_BIN"; : > "$STUB_LOG"
  configure_mount_guard > /dev/null
  [ "$(stat -c %a "$GUARD_BIN")" = 755 ]
  [ "$(stat -c %Y "$GUARD_BIN")" = 1000000000 ]
  ! called "systemctl daemon-reload" || false
}
@test "S28: when seaweed-mount started after clear, reexport re-exports NFS and restarts Samba, and not the NFS server" {
  configure_mount_guard > /dev/null; echo 1000 > /run/seaweedfs-mount-guard; : > "$STUB_LOG"
  run "$GUARD_BIN" reexport
  echo "$output"
  [ "$status" -eq 0 ]
  called "exportfs -ra"
  called "systemctl restart smbd"
  ! grep -q 'systemctl restart nfs' "$STUB_LOG" || false
  [ ! -e /run/seaweedfs-mount-guard ]
}
@test "S28: a live mount but seaweed-mount clean-stopped (a dockerd crash) gives a warning, and Samba and NFS are left alone" {
  configure_mount_guard > /dev/null; date +%s > /run/seaweedfs-mount-guard; echo false > "$T/running"; : > "$STUB_LOG"
  run "$GUARD_BIN" reexport
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: seaweed-mount isn't up"* ]]
  ! called exportfs || false
  ! called "systemctl restart" || false
}
@test "S28: if the mount never comes back, reexport warns and leaves Samba and NFS alone" {
  configure_mount_guard > /dev/null; echo 1000 > /run/seaweedfs-mount-guard; dead; : > "$STUB_LOG"
  run "$GUARD_BIN" reexport
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: seaweed-mount isn't up with a live /mnt/seaweed"* ]]
  ! called exportfs || false
  ! called "systemctl restart" || false
}
@test "S28: a guard an older release's uninstall left behind does nothing" {
  configure_mount_guard > /dev/null; dead; rm -f /opt/seaweedfs/seaweedfs-compose.yaml; : > "$STUB_LOG"
  run "$GUARD_BIN" clear
  [ "$status" -eq 0 ]
  [[ "$output" == *"isn't installed here any more"* ]]
  ! called umount || false
  [ "$CREATED_COMPOSE" = 1 ] || : > /opt/seaweedfs/seaweedfs-compose.yaml
}
