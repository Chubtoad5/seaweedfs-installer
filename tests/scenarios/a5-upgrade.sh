#!/bin/bash
# A5: install the last release (its source archive from GitHub), write an S3 object and a Filer file, then install the
# commit under test over it. The data, the S3 keys, the admin password and Caddy's root CA must all survive.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
R=seaweedfs-installer
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
P=Test-Pass-1 K=aaaa1111bbbb2222 S=cccc3333dddd4444eeee5555ffff6666 B=charlie
export HOST_FQDN=files.test.lab DEBUG=0 SWFS_PASSWORD=$P S3_ACCESS_KEY=$K S3_SECRET_KEY=$S
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true
old=$(curl -sI -m 20 "https://github.com/Chubtoad5/$R/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p')
[[ "$old" =~ ^v[0-9]+(\.[0-9]+)+$ ]] && ok "the last release is $old" || { bad "couldn't find the last release: '$old'"; echo "=== exit 1"; exit 1; }
mkdir old new
curl -sfL -m 180 "https://github.com/Chubtoad5/$R/archive/refs/tags/$old.tar.gz" | tar -xz -C old --strip-components=1 && [ -x old/install-seaweedfs ] \
  && ok "download $old" || { bad "download $old"; echo "=== exit 1"; exit 1; }
cp "$REPO/install-seaweedfs" new/; chmod +x new/install-seaweedfs
s3() { curl -sk -m 30 --aws-sigv4 aws:amz:us-east-1:s3 --user "$K:$S" "$@"; }
s3ok() { [ "$(s3 -o /dev/null -w '%{http_code}' "https://$IP:8333/")" = 200 ]; }
filer_get() { curl -sk -m 30 -u "admin:$P" "https://$IP:8888/artifacts/a5/file.bin"; }
sum() { sha256sum | cut -d' ' -f1; }
ca() { docker exec seaweed-caddy cat /data/caddy/pki/authorities/local/root.crt 2>/dev/null | sum; }
running() { local c; for c in seaweed-mini seaweed-caddy seaweed-mq seaweed-mount grafana loki prometheus; do [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "$c"; return 1; }; done; }

(cd old && ./install-seaweedfs install) > o1 2>&1 && ok "install $old" || { bad "install $old"; tail -8 o1 | cut -c1-170; echo "=== exit 1"; exit 1; }
within 60 s3ok && ok "$old's S3 answers" || bad "$old's S3 doesn't answer"
head -c 200000 /dev/urandom > obj.bin; head -c 200000 /dev/urandom > file.bin
[ "$(s3 -o /dev/null -w '%{http_code}' -T obj.bin "https://$IP:8333/$B/a5/obj.bin")" = 200 ] && ok "write an S3 object" || bad "write an S3 object"
c=$(curl -sk -m 30 -u "admin:$P" -o /dev/null -w '%{http_code}' -F "file=@file.bin" "https://$IP:8888/artifacts/a5/"); [[ "$c" =~ ^20 ]] && ok "write a Filer file" || bad "write a Filer file: $c"
ca1=$(ca); [ -n "$ca1" ] && [ "$ca1" != "$(printf '' | sum)" ] && ok "Caddy's root CA is there" || bad "no Caddy root CA to compare"

(cd new && ./install-seaweedfs install) > o2 2>&1 && ok "install the commit under test over $old" || { bad "install the commit under test over $old"; tail -10 o2 | cut -c1-170; }
w=$(within 90 running) && ok "every container runs after the upgrade" || bad "not running after the upgrade: $w"
within 90 s3ok && ok "S3 answers with the same keys" || bad "S3 doesn't answer with the same keys"
[ "$(s3 "https://$IP:8333/$B/a5/obj.bin" | sum)" = "$(sum < obj.bin)" ] && ok "the S3 object survived" || bad "the S3 object changed or is gone"
[ "$(filer_get | sum)" = "$(sum < file.bin)" ] && ok "the Filer file survived, and the admin password still opens it" || bad "the Filer file changed or is gone, or the password no longer works"
[ "$(ca)" = "$ca1" ] && ok "Caddy's root CA is unchanged, so clients still trust it" || bad "Caddy's root CA changed"
(cd new && ./install-seaweedfs uninstall) > o3 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 o3 | cut -c1-170; }
left=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -xE 'seaweed-.*|grafana|loki|prometheus')
[ -z "$left" ] && ok "no containers left" || bad "containers left behind: $left"
echo "=== exit $fail"; exit $fail
