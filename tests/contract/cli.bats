#!/usr/bin/env bats
# What ap-tools and the blueprints rely on.
SCRIPT="$BATS_TEST_DIRNAME/../../install-seaweedfs"
@test "needs root" {
  run su -s /bin/bash nobody -c "bash '$SCRIPT' install"
  [ "$status" -ne 0 ]
}
@test "help lists the commands consumers call" {
  run "$SCRIPT" help
  [ "$status" -eq 0 ]
  for c in install save uninstall push; do [[ "$output" == *"$c"* ]]; done
}
@test "an unknown argument is an error" {
  run "$SCRIPT" nope
  [ "$status" -ne 0 ]
}
@test "the sentinel and archive names stay the same" {
  grep -q 'swfs-save-version.txt' "$SCRIPT"
  grep -q 'swfs-save.tar.gz' "$SCRIPT"
}
@test "every setting ap-tools forwards is still read" {
  for v in SWFS_IMAGE CADDY_IMAGE SWFS_USER SWFS_PASSWORD HOST_FQDN SWFS_ADMIN_FQDN SWFS_MASTER_FQDN SWFS_FILER_FQDN SWFS_S3_FQDN MGMT_IP SWFS_ADMIN_PORT SWFS_MASTER_PORT SWFS_FILER_PORT SWFS_S3_PORT ENABLE_SMB ENABLE_NFS S3_BUCKET EXTRA_BUCKETS DEFAULT_FILER_DIR_NAME ARTIFACTS_TO_DOWNLOAD ENABLE_MONITORING CLUSTER_NAME; do
    grep -q "^$v=\${$v:-" "$SCRIPT"
  done
}
