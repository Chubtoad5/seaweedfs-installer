#!/bin/bash
# Upgrading from v1.0.0, on a throwaway host, as root, from the repo root: install v1.0.0 with no S3 keys passed, then
# re-run this version the same way. The pair v1.0.0 generated has to survive, and the first re-run tightens the files.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
LOG=$W/seaweedfs-install.log
export HOST_FQDN=files.test.lab SWFS_PASSWORD=Test-Pass-1 DEBUG=0 ENABLE_MONITORING=false
show() { tail -6 "$W/o" | cut -c1-170; }
s3keys() { echo s3.configure | docker exec -i seaweed-mini /usr/bin/weed shell 2>/dev/null | grep -c '"accessKey"'; }
s3ls() { curl -sk -m 10 --aws-sigv4 aws:amz:us-east-1:s3 --user "$1:$2" -o /dev/null -w '%{http_code}' "https://$IP:8333/"; }
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true

if ! curl -fsSL -m 60 -o install-seaweedfs https://github.com/Chubtoad5/seaweedfs-installer/raw/refs/tags/v1.0.0/install-seaweedfs; then
  bad "couldn't download v1.0.0"; echo "=== exit 1"; exit 1
fi
chmod +x install-seaweedfs
./install-seaweedfs install > "$W/o" 2>&1 && ok "install v1.0.0, no S3 keys passed" || { bad "install v1.0.0"; show; }
key=$(sed -n 's/^  API Key:  //p' "$LOG" | tail -1); secret=$(sed -n 's/^  API Secret: //p' "$LOG" | tail -1)
# v1.0.0 doesn't wait for Caddy to answer, so S3 can still be coming up here (000 on Ubuntu minimal, lab run 42487046505).
# Twelve tries, 5 s apart: about a minute, longer if curl hangs to its 10 s limit.
for _ in $(seq 1 12); do [ "$(s3ls "$key" "$secret")" = 200 ] && break; sleep 5; done
[ "$(s3ls "$key" "$secret")" = 200 ] && ok "v1.0.0's key works" || bad "v1.0.0's key got $(s3ls "$key" "$secret")"
n=$(s3keys)

cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
./install-seaweedfs install > "$W/o" 2>&1 && ok "re-run with this version, no S3 keys passed" || { bad "re-run with this version"; show; }
grep -q "keeping the pair" "$W/o" && [ "$(s3keys)" = "$n" ] && ok "the upgrade keeps v1.0.0's key pair, and adds no key" \
  || bad "the upgrade added a key ($n before, $(s3keys) after)"
[ "$(s3ls "$key" "$secret")" = 200 ] && ok "v1.0.0's key still works" || bad "v1.0.0's key got $(s3ls "$key" "$secret")"
[ "$(grep -c '^# BEGIN credentials$' "$LOG")" = 1 ] && [ "$(grep -c "API Key:  $key" "$LOG")" = 1 ] \
  && ok "the log has one credentials block, with that key" || bad "the log doesn't have exactly one block with that key"
for f in /opt/seaweedfs/seaweedfs-compose.yaml /opt/caddy/Caddyfile; do
  [ "$(stat -c %a "$f" 2>/dev/null)" = 600 ] && ok "the upgrade makes $f mode 600" || bad "$f is mode $(stat -c %a "$f" 2>/dev/null)"
done
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$SWFS_PASSWORD" "https://$IP:8888/artifacts/"); [[ "$code" =~ ^[23] ]] && ok "the Filer answers after the upgrade" || bad "the Filer answered $code"
st=$(docker inspect -f '{{.State.StartedAt}}' seaweed-caddy 2>/dev/null)
./install-seaweedfs install > "$W/o" 2>&1 && ok "a second re-run" || { bad "a second re-run"; show; }
[ "$(docker inspect -f '{{.State.StartedAt}}' seaweed-caddy 2>/dev/null)" = "$st" ] && ok "after the upgrade, a re-run doesn't restart Caddy" || bad "a re-run after the upgrade restarted Caddy"
./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }

# A log from another host, as ap-tools' offline-prep bundle carries one: its keys must never go live here.
W2=$(mktemp -d -p /var/tmp); cd "$W2" || exit 1
cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
printf '%s\n' '  API User: admin' '  API Key:  0000aaaa1111bbbb' '  API Secret: 2222cccc3333dddd4444eeee5555ffff' > seaweedfs-install.log
./install-seaweedfs install > "$W/o" 2>&1 && ok "a fresh install, with another host's log in its folder" || { bad "a fresh install with another host's log"; show; }
! grep -q "keeping the pair" "$W/o" && [ "$(s3ls 0000aaaa1111bbbb 2222cccc3333dddd4444eeee5555ffff)" = 403 ] \
  && ok "another host's logged key isn't used" || bad "another host's logged key went live"
./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
[ -z "$(docker ps -q --filter name=seaweed 2>/dev/null)" ] && ok "no containers left" || bad "containers left behind"
echo "=== exit $fail"; exit $fail
