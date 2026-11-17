#!/usr/bin/env bats
# Spec 17: every weed shell the installer runs, or prints for a person to run, names the container's own Filer. In
# cluster mode the control plane advertises the host's address, and the Filer's gRPC port isn't published there, so a
# shell that looks the Filer up itself is refused, and the install stopped at "Configuring S3 credentials".
S=$BATS_TEST_DIRNAME/../../install-seaweedfs

@test "every weed shell names the container's own Filer" {
  # Except join's admission check (spec 24, S38): a volume node runs no Filer, and its cluster.check needs only the master
  run bash -c "grep -n 'weed shell' '$S' | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v -- '-filer=localhost:8888' | grep -vF 'exec -i seaweed-volume timeout 10 /usr/bin/weed shell -master=\"\$CLUSTER_MASTER\" <<< \"cluster.check\"'"
  [ -z "$output" ]
}

@test "there are weed shell calls to check: the S3 keys, buckets, and the cluster steps join prints" {
  [ "$(grep 'weed shell' "$S" | grep -vcE '^[[:space:]]*#')" -ge 7 ]
}
