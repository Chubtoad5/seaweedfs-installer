#!/bin/bash
# A4 on node 1, the control plane. By CI_STEP:
#   node1    install with CLUSTER_MODE=cluster, alone, and write an object (one copy)
#   node1.2  after node 2 joined: the README's two steps (re-run install with CLUSTER_REPLICATION=001, then
#            volume.configure.replication and volume.fix.replication), then check every volume holding our data has a
#            copy on node 2, and write a second object
#   node1.3  node 2 is stopped: read both objects back
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=/var/tmp/a4; mkdir -p "$W"; cd "$W" || exit 1
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
N2=${CI_ROLE_NODE2_IP:?}
P=Test-Pass-1 K=aaaa1111bbbb2222 S=cccc3333dddd4444eeee5555ffff6666 B=charlie
export HOST_FQDN=files.test.lab DEBUG=0 SWFS_PASSWORD=$P S3_ACCESS_KEY=$K S3_SECRET_KEY=$S CLUSTER_MODE=cluster \
  ENABLE_MONITORING=false ENABLE_MQ=false ENABLE_SMB=false ENABLE_NFS=false
s3() { curl -sk -m 30 --aws-sigv4 aws:amz:us-east-1:s3 --user "$K:$S" "$@"; }
s3ok() { [ "$(s3 -o /dev/null -w '%{http_code}' "https://$IP:8333/")" = 200 ]; }
put() { [ "$(s3 -o /dev/null -w '%{http_code}' -T "$2" "https://$IP:8333/$B/a4/$1")" = 200 ]; }
same() { [ "$(s3 "https://$IP:8333/$B/a4/$1" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < "$CI_HANDOFF/$1" | cut -d' ' -f1)" ]; }
shell() { printf '%s\n' "$@" | docker exec -i seaweed-mini weed shell -master=localhost:9333 2>&1; }
# The volume IDs of an object's chunks, from the Filer's entry
vids() { shell "fs.meta.cat /buckets/$B/a4/$1" | grep -oiE '"file_?id": *"[0-9]+,' | grep -oE '[0-9]+' | sort -u; }
# Where the master says a volume is
where() { curl -sk -m 10 -u "admin:$P" "https://$IP:9333/dir/lookup?volumeId=$1" | grep -oE '"url": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sort; }
on_both() { local w; w=$(where "$1"); grep -qx "$IP:9340" <<< "$w" && grep -qx "$N2:9340" <<< "$w"; }

case "${CI_STEP:-node1}" in
node1)
  cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
  systemctl disable --now cockpit.socket >/dev/null 2>&1 || true
  ./install-seaweedfs install > o 2>&1 && ok "install with CLUSTER_MODE=cluster" || { bad "install with CLUSTER_MODE=cluster"; tail -8 o | cut -c1-170; echo "=== exit 1"; exit 1; }
  within 60 s3ok && ok "S3 answers" || bad "S3 doesn't answer"
  head -c 300000 /dev/urandom > before.bin; cp before.bin "$CI_HANDOFF/"
  put before.bin before.bin && ok "write an object on one node" || bad "write an object on one node"
  v=$(vids before.bin); [ -n "$v" ] && ok "the object is in volume(s) $(echo $v)" || bad "no volume found for the object: $(shell "fs.meta.cat /buckets/$B/a4/before.bin" | head -5 | tr '\n' ' ' | cut -c1-160)"
  ;;
node1.2)
  CLUSTER_REPLICATION=001 ./install-seaweedfs install > o2 2>&1 && ok "re-run install with CLUSTER_REPLICATION=001 (README step 1)" \
    || { bad "re-run install with CLUSTER_REPLICATION=001"; tail -8 o2 | cut -c1-170; }
  grep -q 'defaultReplication=001' /opt/seaweedfs/seaweedfs-compose.yaml && ok "the master's default replication is 001" || bad "the compose file has no defaultReplication=001"
  within 90 s3ok && ok "S3 answers after the re-run" || bad "S3 doesn't answer after the re-run"
  same before.bin && ok "the first object survived the re-run" || bad "the first object changed or is gone after the re-run"
  r=$(shell lock 'volume.configure.replication -replication 001' 'volume.fix.replication -apply' unlock)
  ok "configure and fix replication (README step 2)"; echo "$r" | grep -iE 'error|fail' | head -3 | sed 's/^/  /' | cut -c1-170
  for v in $(vids before.bin); do
    within 120 on_both "$v" && ok "volume $v, holding the first object, has a copy on node 2" || bad "volume $v isn't on both nodes: $(where "$v" | tr '\n' ' ')"
  done
  head -c 300000 /dev/urandom > after.bin; cp after.bin "$CI_HANDOFF/"
  put after.bin after.bin && ok "write a second object, after the join" || bad "write a second object, after the join"
  for v in $(vids after.bin); do
    within 60 on_both "$v" && ok "volume $v, holding the second object, is on both nodes" || bad "volume $v, written after the join, isn't on both nodes: $(where "$v" | tr '\n' ' ')"
  done
  # The fids, so node 2 can read its own copies
  { shell "fs.meta.cat /buckets/$B/a4/before.bin" | grep -oiE '"file_?id": *"[0-9]+,[0-9a-f]+"' | sed -E 's/.*"([^"]+)"$/before.bin \1/'
    shell "fs.meta.cat /buckets/$B/a4/after.bin" | grep -oiE '"file_?id": *"[0-9]+,[0-9a-f]+"' | sed -E 's/.*"([^"]+)"$/after.bin \1/'; } > "$CI_HANDOFF/fids"
  [ "$(wc -l < "$CI_HANDOFF/fids")" -ge 2 ] && ok "hand on both objects' chunk IDs" || bad "couldn't read the chunk IDs: $(cat "$CI_HANDOFF/fids")"
  ;;
node1.3)
  for f in before.bin after.bin; do
    within 60 same "$f" && ok "with node 2 stopped, $f reads back unchanged" || bad "with node 2 stopped, $f doesn't read back"
  done
  ;;
esac
echo "=== exit $fail"; exit $fail
