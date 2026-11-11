#!/usr/bin/env bats
# S15: a re-run restarts Samba and NFS only when it must. S16: .install-state records the release that last ran.
# These write /etc/samba/smb.conf and /etc/exports, so they run only as root in a container, as CI's unit tier does.
load ../helpers

setup() {
  [[ $EUID -eq 0 && ( -f /run/.containerenv || -f /.dockerenv ) ]] || skip "writes under /etc: root in a container only"
  setup_stubs
  load_script install-seaweedfs
  T=$(mktemp -d)
  STATE_FILE=$T/state LOG_FILE=$T/install.log
  ID=ubuntu AIR_GAPPED_MODE=1 DEFAULT_FILER_DIR_NAME=artifacts SWFS_USER=admin SWFS_PASSWORD=pw NFS_CLIENTS='*'
  mkdir -p /etc/samba; : > /etc/samba/smb.conf; rm -f /etc/samba/smb.conf.bak; : > /etc/exports
  # Both services running, the mount unchanged since 'compose up', and Samba listening
  touch "$T/active-smbd" "$T/active-nfs-kernel-server"
  echo 101 > "$T/mount"; MOUNT_ID_BEFORE=101
  seaweed_mount_id() { cat "$T/mount"; }
  install_os_packages() { :; }; download_install_packages() { :; }; ensure_swfs_user() { :; }; configure_nfs_meta_refresh() { :; }
  stub systemctl 'case "$1" in is-active) [ -e '"$T"'/active-"$3" ] ;; reload) [ -z "$RELOAD_FAILS" ] ;; restart) touch '"$T"'/active-"$2" ;; *) exit 0 ;; esac'
  stub testparm 'cat /etc/samba/smb.conf'
  stub ss 'echo LISTEN'
  stub smbpasswd 'cat > /dev/null'
  stub exportfs
  stub sleep
}
teardown() { rm -f /etc/samba/smb.conf /etc/samba/smb.conf.bak /etc/exports; }
service_calls() { grep -E '^systemctl (restart|reload|start) |^exportfs' "$STUB_LOG" || true; }

@test "S15: a same-settings Samba run neither restarts nor reloads" {
  run_smb >/dev/null
  : > "$STUB_LOG"
  run run_smb
  [ "$status" -eq 0 ]
  [[ "$output" == *"Samba: no change, left running."* ]]
  [ -z "$(service_calls)" ]
}
@test "S15: a changed smb.conf reloads Samba, and doesn't restart it" {
  run_smb >/dev/null
  : > "$STUB_LOG"; SWFS_USER=other
  run run_smb
  [ "$status" -eq 0 ]
  [ "$(service_calls)" = "systemctl reload smbd" ]
}
@test "S15: a failed reload falls back to a restart" {
  run_smb >/dev/null
  : > "$STUB_LOG"; SWFS_USER=other; export RELOAD_FAILS=1
  run run_smb
  [ "$status" -eq 0 ]
  [ "$(service_calls)" = $'systemctl reload smbd\nsystemctl restart smbd' ]
}
@test "S15: Samba not running is started" {
  run_smb >/dev/null
  : > "$STUB_LOG"; rm "$T/active-smbd"
  run_smb >/dev/null
  [ "$(service_calls)" = "systemctl restart smbd" ]
}
@test "S15: a replaced mount restarts Samba, even with nothing else changed" {
  run_smb >/dev/null
  : > "$STUB_LOG"; echo 202 > "$T/mount"
  run_smb >/dev/null
  [ "$(service_calls)" = "systemctl restart smbd" ]
}
@test "S15: a same-settings NFS run doesn't re-export or restart" {
  run_nfs >/dev/null
  : > "$STUB_LOG"
  run run_nfs
  [ "$status" -eq 0 ]
  [[ "$output" == *"NFS: no change, left running."* ]]
  [ -z "$(service_calls)" ]
}
@test "S15: a changed export re-exports without a restart" {
  run_nfs >/dev/null
  : > "$STUB_LOG"; NFS_CLIENTS=10.0.0.0/24
  run_nfs >/dev/null
  [ "$(service_calls)" = "exportfs -ra" ]
}
@test "S15: NFS not running is exported and started" {
  rm "$T/active-nfs-kernel-server"
  run_nfs >/dev/null
  [ "$(service_calls)" = $'exportfs -ra\nsystemctl restart nfs-kernel-server' ]
}
@test "S15: a replaced mount re-exports and restarts NFS" {
  run_nfs >/dev/null
  : > "$STUB_LOG"; echo 202 > "$T/mount"
  run_nfs >/dev/null
  [ "$(service_calls)" = $'exportfs -ra\nsystemctl restart nfs-kernel-server' ]
}
@test "S15: no mount before 'compose up' counts as a new mount" {
  MOUNT_ID_BEFORE=""
  mount_replaced
  MOUNT_ID_BEFORE=101
  ! mount_replaced || false
}
@test "S15: seaweed_mount_id reads the top mount at /mnt/seaweed" {
  unset -f seaweed_mount_id; load_script install-seaweedfs
  [[ "$(declare -f seaweed_mount_id)" == *'$5 == "/mnt/seaweed"'* ]]
  # On a host with nothing mounted there, it's empty
  [ -z "$(seaweed_mount_id)" ] || grep -q ' /mnt/seaweed ' /proc/self/mountinfo
}
@test "S16: install and join record SCRIPT_VERSION as their last step" {
  last_line() { declare -f "$1" | grep -v '^ *}$' | tail -1 | sed 's/^ *//; s/;$//'; }
  [ "$(last_line install_swfs)" = 'record_state SCRIPT_VERSION "$SCRIPT_VERSION"' ]
  [ "$(last_line run_join)" = 'record_state SCRIPT_VERSION "$SCRIPT_VERSION"' ]
  record_state SCRIPT_VERSION "$SCRIPT_VERSION"
  [ "$(get_state SCRIPT_VERSION)" = "$SCRIPT_VERSION" ]
}
