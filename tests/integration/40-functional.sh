#!/bin/bash
# What SeaweedFS is for, on a throwaway host, as root, from the repo root (spec 09's C1, in the chubtoad-automation project):
# S3 with the real keys, SMB and NFS on the same files, the NFS refresh timer, MQ, the monitoring stack, Caddy's CA across a
# container recreate, then a push to a registry and an install from it. Runs after 30-upgrade.sh, which leaves the host
# uninstalled. The registry part needs a Harbor: CI's lab run gives one (CI_SUPPORT_REGISTRY, with an account of this job's
# own), and without it that part is skipped. The test's own tools come from containers, so they can't stand in for anything
# the installer should have installed: S3 with curl, SMB with smbclient in an Alpine container.
set -uo pipefail
REPO=$PWD
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
skip() { echo "SKIP  $1"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
P=Test-Pass-1 K=aaaa1111bbbb2222 S=cccc3333dddd4444eeee5555ffff6666
export HOST_FQDN=files.test.lab DEBUG=0 SWFS_PASSWORD=$P S3_ACCESS_KEY=$K S3_SECRET_KEY=$S \
  EXTRA_BUCKETS="ci-extra-a ci-extra-b" NFS_META_REFRESH_SEC=10
show() { tail -6 "$W/o" | cut -c1-170; }
s3() { curl -sk -m 20 --aws-sigv4 aws:amz:us-east-1:s3 --user "$K:$S" "$@"; }
code() { curl -sk -m 20 -o /dev/null -w '%{http_code}' "$@"; }
filer() { curl -sk -m 20 -u "admin:$P" "$@"; }
filer_is() { [ "$(filer "https://$IP:8888/artifacts/$1")" = "$2" ]; }
# within <seconds> <command...>: true once the command is, checking every 2 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 2)); do "$@" && return 0; sleep 2; done; "$@"; }
smb() { docker run --rm --network host -v "$W/smb:/w" alpine:3.20 sh -c \
  "apk add -q --no-cache samba-client >/dev/null 2>&1 && cd /w && smbclient -m SMB3 //$IP/artifacts -U 'admin%$P' -c '$1'" > "$W/smb.out" 2>&1; }
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true

echo "=== Install with SMB, NFS, MQ, monitoring and two extra buckets"
if ! ./install-seaweedfs install > "$W/o" 2>&1; then
  bad "install"; show; echo "=== exit 1"; exit 1
fi
ok "install"

echo "=== S3, with the installer's keys"
list=$(s3 "https://$IP:8333/")
for b in charlie ci-extra-a ci-extra-b loki-logs; do
  [[ "$list" == *"<Name>$b</Name>"* ]] && ok "bucket $b is there" || bad "bucket $b is missing: $(head -c 300 <<< "$list")"
done
[ "$(s3 -o /dev/null -w '%{http_code}' -X PUT "https://$IP:8333/ci-c1")" = 200 ] && ok "create a bucket" || bad "create a bucket"
head -c 200000 /dev/urandom > "$W/obj"
[ "$(s3 -o /dev/null -w '%{http_code}' -T "$W/obj" "https://$IP:8333/ci-c1/obj.bin")" = 200 ] && ok "put an object" || bad "put an object"
s3 -o "$W/obj.back" "https://$IP:8333/ci-c1/obj.bin"
cmp -s "$W/obj" "$W/obj.back" && ok "get it back, byte for byte" || bad "the object read back differs"
[ "$(s3 -o /dev/null -w '%{http_code}' -X DELETE "https://$IP:8333/ci-c1/obj.bin")" = 204 ] && ok "delete it" || bad "delete it"
[ "$(s3 -o /dev/null -w '%{http_code}' "https://$IP:8333/ci-c1/obj.bin")" = 404 ] && ok "a deleted object is gone" || bad "a deleted object still answers"
c=$(curl -sk -m 20 --aws-sigv4 aws:amz:us-east-1:s3 --user "$K:wrong-secret-0000" -o /dev/null -w '%{http_code}' "https://$IP:8333/")
[ "$c" = 403 ] && ok "a wrong secret is refused" || bad "a wrong secret got $c"

echo "=== SMB and NFS see the same files, and so does the Filer"
mkdir -p "$W/smb" /mnt/ci-nfs
if mount -t nfs -o vers=3,nolock "$IP:/mnt/seaweed" /mnt/ci-nfs; then
  ok "mount the NFS export"
  echo "from smb $$" > "$W/smb/via-smb.txt"
  smb 'put via-smb.txt' && ok "write a file over SMB" || { bad "write a file over SMB"; tail -3 "$W/smb.out"; }
  [ "$(cat /mnt/ci-nfs/via-smb.txt 2>/dev/null)" = "from smb $$" ] && ok "read it over NFS" || bad "NFS doesn't show the SMB file"
  [ "$(filer "https://$IP:8888/artifacts/via-smb.txt")" = "from smb $$" ] && ok "read it from the Filer" || bad "the Filer doesn't show the SMB file"
  echo "from nfs $$" > /mnt/ci-nfs/via-nfs.txt && sync && ok "write a file over NFS" || bad "write a file over NFS"
  rm -f "$W/smb/via-nfs.txt"
  smb 'get via-nfs.txt' && [ "$(cat "$W/smb/via-nfs.txt" 2>/dev/null)" = "from nfs $$" ] && ok "read it over SMB" || { bad "SMB doesn't show the NFS file"; tail -3 "$W/smb.out"; }
  within 20 filer_is via-nfs.txt "from nfs $$" && ok "read it from the Filer" || bad "the Filer doesn't show the NFS file"
  c=$(docker run --rm --network host alpine:3.20 sh -c "apk add -q --no-cache samba-client >/dev/null 2>&1 && smbclient -m SMB3 //$IP/artifacts -U 'admin%wrong' -c ls" 2>&1)
  [[ "$c" == *NT_STATUS_LOGON_FAILURE* ]] && ok "SMB refuses a wrong password" || bad "SMB with a wrong password: $(tail -2 <<< "$c")"
  # The refresh timer: a file written straight to the Filer, around SMB and NFS, shows over NFS within a few runs of it.
  systemctl is-active -q seaweedfs-nfs-meta-refresh.timer && ok "the NFS refresh timer is active" || bad "the NFS refresh timer isn't active"
  ls /mnt/ci-nfs >/dev/null
  echo "from the filer $$" > "$W/via-filer.txt"
  filer -F "file=@$W/via-filer.txt" "https://$IP:8888/artifacts/" >/dev/null
  filer_is via-filer.txt "from the filer $$" || bad "the upload to the Filer didn't work, so the next check can't mean anything"
  within 45 test -e /mnt/ci-nfs/via-filer.txt && ok "a file written to the Filer shows over NFS within 45 s (NFS_META_REFRESH_SEC=10)" \
    || bad "a file written to the Filer didn't show over NFS in 45 s"
  umount /mnt/ci-nfs || umount -l /mnt/ci-nfs
else
  bad "mount the NFS export"
fi
rmdir /mnt/ci-nfs 2>/dev/null

echo "=== MQ"
# SeaweedFS 4.30 has no command that sends or reads a message, and its Kafka gateway (experimental) never delivered one in
# spec 09's tries. So this checks what the broker does: it's registered, and it takes a topic and leads its partition.
wshell() { echo "$1" | docker exec -i seaweed-mini weed shell 2>&1; }
mq_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' seaweed-mq 2>/dev/null)
mq_registered() { wshell mq.topic.list | grep -q "$mq_ip:17777"; }
within 30 mq_registered && ok "the broker is registered with the master" || bad "the master doesn't list the broker ($mq_ip)"
mq_topic() { wshell "mq.topic.configure -namespace=ci -topic=c1 -partitionCount=2" > "$W/mq.out"; grep -q "\"leader_broker\": \"$mq_ip:17777\"" "$W/mq.out"; }
within 30 mq_topic && ok "a new topic gets the broker as its partitions' leader" \
  || { bad "configure a topic"; tail -5 "$W/mq.out"; }
grep -q 'namespace:"ci" name:"c1"' <<< "$(wshell mq.topic.list)" && ok "the topic is listed" || bad "the topic isn't listed"

echo "=== Monitoring"
c=$(code -u "admin:$P" "https://$IP:3000/api/user"); [ "$c" = 200 ] && ok "log in to Grafana" || bad "Grafana login got $c"
c=$(code -u "admin:wrong" "https://$IP:3000/api/user"); [ "$c" = 401 ] && ok "Grafana refuses a wrong password" || bad "Grafana with a wrong password got $c"
for ds in Prometheus Loki; do
  h=$(curl -sk -m 20 -u "admin:$P" "https://$IP:3000/api/datasources/name/$ds" | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)
  c=$(code -u "admin:$P" "https://$IP:3000/api/datasources/uid/$h/health")
  [ "$c" = 200 ] && ok "Grafana's $ds datasource is healthy" || bad "Grafana's $ds datasource health got $c"
done
up_all() { q=$(curl -s -m 10 "http://127.0.0.1:9090/api/v1/query?query=up"); n=$(grep -o '"value":\[[^]]*"1"\]' <<< "$q" | wc -l); [ "$n" -ge 3 ]; }
within 60 up_all && ok "Prometheus scrapes its targets, each up" || bad "Prometheus: $(head -c 300 <<< "$q")"
line="ci-c1 log line $$ $(date +%s)"
c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "http://$IP:3100/loki/api/v1/push" \
  -d "{\"streams\":[{\"stream\":{\"job\":\"ci-c1\",\"cluster\":\"edge-lab\"},\"values\":[[\"$(date +%s%N)\",\"$line\"]]}]}")
[ "$c" = 204 ] && ok "push a log line to Loki" || bad "Loki push got $c"
loki_has() { curl -s -m 10 -G "http://$IP:3100/loki/api/v1/query_range" --data-urlencode 'query={job="ci-c1"}' \
  --data-urlencode "start=$(( $(date +%s) - 600 ))000000000" | grep -qF "$line"; }
within 60 loki_has && ok "read it back from Loki" || bad "Loki doesn't return the line"

echo "=== Caddy's CA survives a recreate"
root=/opt/caddy/data/caddy/pki/authorities/local/root.crt
cp "$root" "$W/root.before" 2>/dev/null || bad "no $root"
docker rm -f seaweed-caddy >/dev/null
./install-seaweedfs install > "$W/o" 2>&1 && ok "re-run after removing Caddy's container" || { bad "re-run after removing Caddy's container"; show; }
cmp -s "$root" "$W/root.before" && ok "Caddy's root CA is the same file" || bad "Caddy's root CA changed"
v=$(within 30 sh -c "openssl s_client -connect $IP:443 -CAfile $W/root.before </dev/null 2>/dev/null | grep -q 'Verify return code: 0'" && echo yes)
[ "$v" = yes ] && ok "the new container's certificate chains to the old root" || bad "the certificate doesn't chain to the old root"

echo "=== Push to a registry, then install from it"
if [ -z "${CI_SUPPORT_REGISTRY:-}" ]; then
  skip "the registry checks: no CI_SUPPORT_REGISTRY (CI's lab runs give one)"
else
  R=$CI_SUPPORT_REGISTRY RU=$CI_SUPPORT_REGISTRY_USER RP=$CI_SUPPORT_REGISTRY_PASSWORD
  h() { curl -sk -m 20 -u "$RU:$RP" -H 'Content-Type: application/json' "$@"; }
  # images-pull-push keeps each image's path, so Harbor needs a project per namespace. library comes with Harbor.
  for p in chrislusf grafana prom; do
    c=$(h -o /dev/null -w '%{http_code}' -X POST "https://$R/api/v2.0/projects" -d "{\"project_name\":\"$p\",\"metadata\":{\"public\":\"false\"}}")
    [[ "$c" == 201 || "$c" == 409 ]] || bad "create Harbor project $p: $c"
  done
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ./install-seaweedfs push -registry "$R" "$RU" "$RP" > "$W/o" 2>&1 && ok "push to the registry" || { bad "push to the registry"; show; }
  for repo in chrislusf/seaweedfs library/caddy grafana/loki grafana/grafana-oss prom/prometheus; do
    c=$(h -o /dev/null -w '%{http_code}' "https://$R/api/v2.0/projects/${repo%%/*}/repositories/${repo#*/}")
    [ "$c" = 200 ] && ok "$repo is in the registry" || bad "$repo isn't in the registry ($c)"
  done
  ./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
  # With no copy on the host, the install has to pull every image from the registry.
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'seaweedfs|caddy|grafana|loki|prometheus' | xargs -r docker rmi -f >/dev/null 2>&1
  ./install-seaweedfs install -registry "$R" "$RU" "$RP" > "$W/o" 2>&1 && ok "install from the registry" || { bad "install from the registry"; show; }
  for c in seaweed-mini seaweed-caddy seaweed-mq seaweed-mount grafana loki prometheus; do
    img=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)
    [[ "$img" == "$R/"* ]] && ok "$c runs ${img#"$R"/} from the registry" || bad "$c runs '$img', not from the registry"
  done
  # Harbor's own log: this job's account pulled them. The account is this job's alone, so other distros' pulls don't count.
  pulls=$(h "https://$R/api/v2.0/auditlog-exts?page_size=100&q=operation%3Dpull%2Cusername%3D$RU%2Cop_time%3D%5B$since~$(date -u +%Y-%m-%dT%H:%M:%SZ)%5D")
  n=$(grep -o '"operation":"pull"' <<< "$pulls" | wc -l)
  [ "$n" -ge 5 ] && ok "Harbor's audit log has $n pulls by this job's account" || bad "Harbor's audit log has $n pulls by this job's account: $(head -c 200 <<< "$pulls")"
  [ "$(s3 -o /dev/null -w '%{http_code}' "https://$IP:8333/")" = 200 ] && ok "S3 works after the install from the registry" || bad "S3 after the install from the registry"
fi

./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
left=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -xE 'seaweed-.*|grafana|loki|prometheus')
[ -z "$left" ] && ok "no containers left" || bad "containers left behind: $left"
echo "=== exit $fail"; exit $fail
