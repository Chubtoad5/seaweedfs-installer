#!/bin/bash
# A1, on a host with no route out: install from the bundle the build role made, check it serves, uninstall.
# SMB, NFS and monitoring are on, as by default, so their packages and images have to come from the bundle.
set -uo pipefail
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
P=Test-Pass-1 K=aaaa1111bbbb2222 S=cccc3333dddd4444eeee5555ffff6666
export HOST_FQDN=files.test.lab DEBUG=0 SWFS_PASSWORD=$P S3_ACCESS_KEY=$K S3_SECRET_KEY=$S
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true
tar -xzf "$CI_HANDOFF/swfs-save.tar.gz" && ok "unpack the bundle" || { bad "unpack the bundle"; echo "=== exit 1"; exit 1; }
./install-seaweedfs install > "$W/o" 2>&1 && ok "install with no route out" || { bad "install with no route out"; tail -8 "$W/o" | cut -c1-170; }
grep -q "AIR_GAPPED_MODE: 1" "$W/o" "$W/seaweedfs-install.log" 2>/dev/null && ok "it installs from the bundle" || bad "it didn't install in air-gapped mode"
for c in seaweed-mini seaweed-caddy seaweed-mq seaweed-mount grafana loki prometheus; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && ok "$c is running" || bad "$c isn't running"
done
s3ok() { [ "$(curl -sk -m 10 --aws-sigv4 aws:amz:us-east-1:s3 --user "$K:$S" -o /dev/null -w '%{http_code}' "https://$IP:8333/")" = 200 ]; }
within 60 s3ok && ok "S3 answers with the keys" || bad "S3 doesn't answer"
c=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$P" "https://$IP:8888/artifacts/"); [[ "$c" =~ ^[23] ]] && ok "the Filer answers" || bad "the Filer answered $c"
systemctl is-active -q smbd 2>/dev/null || systemctl is-active -q smb 2>/dev/null && ok "Samba, from the bundle, runs" || bad "Samba isn't running"
nfs_up() { systemctl is-active -q nfs-server 2>/dev/null || systemctl is-active -q nfs-kernel-server 2>/dev/null; }
grep -q '/mnt/seaweed' /etc/exports && nfs_up && ok "the NFS server, from the bundle, exports the mount" || bad "the NFS server isn't exporting /mnt/seaweed"
./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
left=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -xE 'seaweed-.*|grafana|loki|prometheus')
[ -z "$left" ] && ok "no containers left" || bad "containers left behind: $left"
echo "=== exit $fail"; exit $fail
