#!/usr/bin/env bats
# The source guard: tests can load this script's functions without running its main logic.
load ../helpers
@test "sourcing defines functions and runs nothing" {
  load_script install-seaweedfs
  declare -F | grep -q .
}
@test "a save that can't get back to its directory fails, rather than exiting 0 with no archive" {
  load_script install-seaweedfs
  W=$(mktemp -d)
  base_dir=$W/work; LOG_FILE=$W/save.log; NFS_PACKAGE=nfs; ENABLE_MONITORING=false
  mkdir -p "$base_dir/utilities"
  debug_run() { "$@"; }
  download_image_pull_push() { :; }
  download_install_packages() { :; }
  # The image save takes the directory away, as a removed mount would.
  printf '#!/bin/bash\nmv "%s" "%s.gone"\n' "$base_dir" "$base_dir" > "$base_dir/utilities/image_pull_push.sh"
  printf '#!/bin/bash\nexit 0\n' > "$base_dir/utilities/install_packages.sh"
  chmod +x "$base_dir"/utilities/*.sh
  run run_save
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot return to"* ]]
}
