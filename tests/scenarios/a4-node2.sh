#!/bin/bash
# A4 on node 2, a volume node. By CI_STEP:
#   node2    join node 1's cluster with the image the last release pinned (spec 24: a 4.30 volume node under a 4.54
#            control plane, as a cluster is mid-upgrade when the README's order is followed)
#   node2.2  read each object's chunk from this node's own volume server, then stop it
#   node2.3  start it again, check it registers, re-run join with this commit's image (the README's last upgrade step),
#            check it registers again and its copies read back unchanged, then uninstall the volume node
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=/var/tmp/a4; mkdir -p "$W"; cd "$W" || exit 1
N1=${CI_ROLE_NODE1_IP:?}
P=Test-Pass-1
export HOST_FQDN=files.test.lab DEBUG=0
vol_up() { curl -s -m 5 -o /dev/null "http://127.0.0.1:9340/status"; }
registered() { curl -sk -m 10 -u "admin:$P" "https://$N1:9333/dir/status" | grep -q "$CI_CLONE_IP:9340"; }
pin() { sed -n 's/^SWFS_IMAGE=${SWFS_IMAGE:-"\(.*\)"}$/\1/p' "$1"; }
image() { docker inspect -f '{{.Config.Image}}' seaweed-volume 2>/dev/null; }
copies_same() { # copies_same <when>: this node's own copy of each object is the same bytes
  local f fid
  while read -r f fid; do
    [ "$(curl -s -m 30 "http://127.0.0.1:9340/$fid" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < "$CI_HANDOFF/$f" | cut -d' ' -f1)" ] \
      && ok "$1: this node's own copy of $f ($fid) is the same bytes" || bad "$1: this node's copy of $f ($fid) differs or is missing"
  done < "$CI_HANDOFF/fids"
}

case "${CI_STEP:-node2}" in
node2)
  cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
  systemctl disable --now cockpit.socket >/dev/null 2>&1 || true
  # The last release's pinned image, so the volume node starts one version behind the control plane when the pin moves
  old=$(curl -sI -m 20 "https://github.com/Chubtoad5/seaweedfs-installer/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p')
  curl -sfL -m 60 -o last-release "https://raw.githubusercontent.com/Chubtoad5/seaweedfs-installer/$old/install-seaweedfs"
  img_old=$(pin last-release) img_new=$(pin install-seaweedfs)
  [ -n "$img_old" ] && ok "the last release ($old) pins $img_old; this commit pins $img_new" || { bad "couldn't read the last release's image ('$old')"; img_old=$img_new; }
  printf '%s\n' "$img_old" > "$W/img_old"
  SWFS_IMAGE=$img_old ./install-seaweedfs join -master "$N1:9333" > o 2>&1 && ok "join node 1's cluster with $img_old" || { bad "join node 1's cluster with $img_old"; tail -8 o | cut -c1-170; echo "=== exit 1"; exit 1; }
  [ "$(image)" = "$img_old" ] && ok "seaweed-volume runs $img_old" || bad "seaweed-volume runs $(image), not $img_old"
  [ "$(docker inspect -f '{{.State.Running}}' seaweed-volume 2>/dev/null)" = true ] && ok "seaweed-volume is running" || bad "seaweed-volume isn't running"
  within 60 vol_up && ok "its volume server answers" || bad "its volume server doesn't answer"
  within 90 registered && ok "node 1's master lists this node" || bad "node 1's master doesn't list this node"
  ;;
node2.2)
  copies_same "on $(image)"
  docker stop seaweed-volume >/dev/null && ok "stop this node's volume server" || bad "stop this node's volume server"
  ;;
node2.3)
  docker start seaweed-volume >/dev/null && within 60 vol_up && ok "start it again" || bad "it doesn't start again"
  within 90 registered && ok "it registers with node 1 again" || bad "it doesn't register with node 1 again"
  img_new=$(pin install-seaweedfs)
  ./install-seaweedfs join -master "$N1:9333" > o2 2>&1 && ok "re-run join with this commit's image, $img_new" || { bad "re-run join with $img_new"; tail -8 o2 | cut -c1-170; }
  [ "$(image)" = "$img_new" ] && ok "seaweed-volume now runs $img_new (it ran $(cat "$W/img_old" 2>/dev/null))" || bad "seaweed-volume runs $(image), not $img_new"
  within 60 vol_up && within 90 registered && ok "after the re-join, it registers with node 1" || bad "after the re-join, it doesn't register with node 1"
  copies_same "after the re-join on $img_new"
  ./install-seaweedfs uninstall > o3 2>&1 && ok "uninstall the volume node" || { bad "uninstall the volume node"; tail -6 o3 | cut -c1-170; }
  docker ps -a --format '{{.Names}}' | grep -qx seaweed-volume && bad "seaweed-volume is still there" || ok "seaweed-volume is gone"
  [ ! -e /opt/seaweedfs ] && ok "/opt/seaweedfs is gone" || bad "/opt/seaweedfs is still there"
  ;;
esac
echo "=== exit $fail"; exit $fail
