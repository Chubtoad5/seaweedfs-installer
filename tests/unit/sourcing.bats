#!/usr/bin/env bats
# The source guard: tests can load this script's functions without running its main logic.
load ../helpers
@test "sourcing defines functions and runs nothing" {
  load_script install-seaweedfs
  declare -F | grep -q .
}
