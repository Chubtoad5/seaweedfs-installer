#!/usr/bin/env bats
# Spec 12: image_pull_push.sh and install_packages.sh come from releases, not main. A copy is reused only when its .ref
# record matches, an air-gapped run never downloads, and one INSTALL_PACKAGES_REF covers both helpers.
load ../helpers

setup() {
  setup_stubs
  unset IMAGE_PULL_PUSH_REF IMAGE_PULL_PUSH_URL IMAGE_PULL_PUSH_SHA256 INSTALL_PACKAGES_REF INSTALL_PACKAGES_URL INSTALL_PACKAGES_SHA256
  load_script install-seaweedfs
  base_dir=$BATS_TEST_TMPDIR/b
  LOG_FILE=$BATS_TEST_TMPDIR/install.log
  AIR_GAPPED_MODE=0 SAVE_MODE=0
  U=$base_dir/utilities
  # A curl that writes a small script to its -o path
  stub curl 'out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
printf "#!/bin/bash\necho helper\n" > "$out"'
}
helper_sha() { printf '#!/bin/bash\necho helper\n' | sha256sum | cut -d' ' -f1; }

@test "image_pull_push.sh comes from images-pull-push v1.2.1, by tag" {
  run download_image_pull_push
  [ "$status" -eq 0 ]
  called "curl -fsSL https://raw.githubusercontent.com/Chubtoad5/images-pull-push/v1.2.1/image_pull_push.sh"
  [ -x "$U/image_pull_push.sh" ]
  [ "$(cat "$U/.image_pull_push.sh.ref")" = v1.2.1 ]
}
@test "install_packages.sh comes from install-packages v1.1.3, by tag" {
  run download_install_packages
  [ "$status" -eq 0 ]
  called "curl -fsSL https://raw.githubusercontent.com/Chubtoad5/install-packages/v1.1.3/install_packages.sh"
  [ -x "$U/install_packages.sh" ]
  [ "$(cat "$U/.install_packages.sh.ref")" = v1.1.3 ]
}
@test "the refs set the URLs" {
  export IMAGE_PULL_PUSH_REF=v9.9.9 INSTALL_PACKAGES_REF=v8.8.8
  unset IMAGE_PULL_PUSH_URL INSTALL_PACKAGES_URL
  load_script install-seaweedfs
  [ "$IMAGE_PULL_PUSH_URL" = "https://raw.githubusercontent.com/Chubtoad5/images-pull-push/v9.9.9/image_pull_push.sh" ]
  [ "$INSTALL_PACKAGES_URL" = "https://raw.githubusercontent.com/Chubtoad5/install-packages/v8.8.8/install_packages.sh" ]
}
@test "a URL wins over its ref" {
  IMAGE_PULL_PUSH_URL=https://mirror.example/ipp.sh INSTALL_PACKAGES_URL=https://mirror.example/ip.sh
  download_image_pull_push >/dev/null
  download_install_packages >/dev/null
  called "curl -fsSL https://mirror.example/ipp.sh"
  called "curl -fsSL https://mirror.example/ip.sh"
}
@test "INSTALL_PACKAGES_REF is exported, so image_pull_push.sh fetches the same install_packages.sh" {
  run bash -c 'echo "$INSTALL_PACKAGES_REF"'
  [ "$output" = v1.1.3 ]
}
@test "a copy whose record names the same ref is reused" {
  download_install_packages >/dev/null
  : > "$STUB_LOG"
  run download_install_packages
  [ "$status" -eq 0 ]
  ! called "curl" || false
}
@test "a copy from another ref, or with no record, is fetched again" {
  mkdir -p "$U"
  echo old > "$U/image_pull_push.sh"
  echo old > "$U/install_packages.sh"
  echo main > "$U/.install_packages.sh.ref"
  download_image_pull_push >/dev/null
  download_install_packages >/dev/null
  grep -q "echo helper" "$U/image_pull_push.sh"
  grep -q "echo helper" "$U/install_packages.sh"
  [ "$(cat "$U/.install_packages.sh.ref")" = v1.1.3 ]
}
@test "a matching checksum passes" {
  INSTALL_PACKAGES_SHA256=$(helper_sha)
  run download_install_packages
  [ "$status" -eq 0 ]
  [ -x "$U/install_packages.sh" ]
}
@test "a checksum mismatch stops, and leaves no file behind" {
  IMAGE_PULL_PUSH_SHA256=$(printf '0%.0s' {1..64})
  run download_image_pull_push
  [ "$status" -eq 1 ]
  [[ "$output" == *"doesn't match its checksum"* ]]
  [ ! -e "$U/image_pull_push.sh" ]
  [ ! -e "$U/image_pull_push.sh.tmp" ]
  [ ! -e "$U/.image_pull_push.sh.ref" ]
}
@test "a failed download stops, and leaves no file behind" {
  stub curl 'exit 22'
  run download_install_packages
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch install_packages.sh"* ]]
  [ ! -e "$U/install_packages.sh" ]
  [ ! -e "$U/install_packages.sh.tmp" ]
}
@test "air-gapped, the bundled copies are used as they are, with no download" {
  AIR_GAPPED_MODE=1
  mkdir -p "$U"
  echo bundled > "$U/image_pull_push.sh"
  echo bundled > "$U/install_packages.sh"
  download_image_pull_push
  download_install_packages
  ! called "curl" || false
  [ "$(cat "$U/install_packages.sh")" = bundled ]
}
@test "air-gapped with no bundled copy stops, and never downloads" {
  AIR_GAPPED_MODE=1
  run download_install_packages
  [ "$status" -eq 1 ]
  [[ "$output" == *"Extract the whole swfs-save.tar.gz"* ]]
  ! called "curl" || false
}
@test "a save fetches the pinned copies even where a left-over sentinel made the run air-gapped" {
  AIR_GAPPED_MODE=1 SAVE_MODE=1
  mkdir -p "$U"
  echo old > "$U/image_pull_push.sh"
  echo old > "$U/install_packages.sh"
  download_image_pull_push >/dev/null
  download_install_packages >/dev/null
  [ "$(cat "$U/.image_pull_push.sh.ref")" = v1.2.1 ]
  [ "$(cat "$U/.install_packages.sh.ref")" = v1.1.3 ]
  grep -q "echo helper" "$U/install_packages.sh"
}
@test "nothing fetches a helper from main any more" {
  ! grep -nE '(images-pull-push|install-packages)/raw/refs/heads/main' "$BATS_TEST_DIRNAME/../../install-seaweedfs" || false
}
