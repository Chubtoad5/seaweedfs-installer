#!/bin/bash
# The Day-2 fixes (v1.1.0) on a throwaway host, as root, from the repo root. Each check here failed at v1.0.0.
# Runs after 10-lifecycle.sh, which leaves the host uninstalled. Takes about 20 minutes.
set -uo pipefail
REPO=$PWD
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
skip() { echo "SKIP  $1"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
LOG=$W/seaweedfs-install.log
export HOST_FQDN=files.test.lab DEBUG=0
P1=Test-Pass-1 P2=Test-Pass-2
K1=aaaa1111bbbb2222 S1=cccc3333dddd4444eeee5555ffff6666
K2=1111aaaa2222bbbb S2=3333cccc4444dddd5555eeee6666ffff
# inst <env...>: install with these settings; the output goes to $W/o
inst() { env "$@" ./install-seaweedfs install > "$W/o" 2>&1; }
show() { tail -6 "$W/o" | cut -c1-170; }
s3ls() { curl -sk -m 10 --aws-sigv4 aws:amz:us-east-1:s3 --user "$1:$2" -o /dev/null -w '%{http_code}' "https://$IP:8333/"; }
s3keys() { echo s3.configure | docker exec -i seaweed-mini /usr/bin/weed shell 2>/dev/null | grep -c '"accessKey"'; }
started() { docker inspect -f '{{.State.StartedAt}}' seaweed-caddy 2>/dev/null; }
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
# Rocky's image has Cockpit on 9090, which Prometheus needs. 10-lifecycle.sh frees it; this does too, when run alone.
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true
state_value() { sed -n "s/^$1=//p" /opt/seaweedfs/.install-state 2>/dev/null; }
smb_pid() { systemctl show -p MainPID --value "$(state_value SMB_SERVICE_NAME)"; }
nfs_started() { systemctl show -p ActiveEnterTimestamp --value "$(state_value NFS_SERVICE_NAME)"; }
# S15: an SMB session held open across a re-run. smbclient reads its commands from a FIFO, and writes its output when
# it exits. end_smb sends a second listing and is true when both listings came back with no NT_STATUS error.
hold_smb() {
  mkdir -p "$W/hold"; rm -f "$W/hold/in" "$W/hold/out"; mkfifo "$W/hold/in"; exec 7<>"$W/hold/in"
  docker rm -f smbhold >/dev/null 2>&1
  docker run -d --name smbhold --network host -v "$W/hold:/w" alpine:3.20 sh -c \
    "apk add -q --no-cache samba-client >/dev/null 2>&1 && smbclient -m SMB3 //$IP/artifacts -U '$1%$2' < /w/in > /w/out 2>&1" >/dev/null
  for _ in $(seq 1 60); do smbstatus -b 2>/dev/null | grep -q " $1 " && break; sleep 1; done
  echo ls >&7
}
end_smb() {
  echo ls >&7; echo exit >&7; timeout 30 docker wait smbhold >/dev/null 2>&1; exec 7>&-; docker rm -f smbhold >/dev/null 2>&1
  [ "$(grep -c 'blocks of size' "$W/hold/out")" = 2 ] && ! grep -q NT_STATUS "$W/hold/out"
}

echo "=== S10: no MGMT_IP"
mkdir -p "$W/stub"
printf '#!/bin/sh\n[ "$1" = "-I" ] && exit 0\nexec %s "$@"\n' "$(command -v hostname)" > "$W/stub/hostname"; chmod +x "$W/stub/hostname"
if PATH="$W/stub:$PATH" ./install-seaweedfs install > "$W/o" 2>&1; then bad "installed with no address"
elif grep -q "valid MGMT_IP" "$W/o" && [ ! -e /opt/caddy/Caddyfile ]; then ok "refuses with no address, and changes nothing"
else bad "the refusal doesn't name MGMT_IP, or a Caddyfile was written"; show; fi

echo "=== Install, then an identical re-run (S3, S5, S7, S8)"
inst SWFS_PASSWORD=$P1 S3_ACCESS_KEY=$K1 S3_SECRET_KEY=$S1 && ok "install" || { bad "install"; show; }
for f in /opt/seaweedfs/seaweedfs-compose.yaml /opt/monitoring/docker-compose.yml /opt/caddy/Caddyfile /opt/caddy/.auth-hash; do
  [ "$(stat -c %a "$f" 2>/dev/null)" = 600 ] && ok "$f is mode 600" || bad "$f is mode $(stat -c %a "$f" 2>/dev/null)"
done
su -s /bin/sh nobody -c "cat /opt/seaweedfs/seaweedfs-compose.yaml /opt/monitoring/docker-compose.yml" >/dev/null 2>&1 \
  && bad "another user can read the compose files" || ok "another user can't read the compose files"
grep -q '"accessKey"' "$LOG" && bad "the log has the raw S3 identity output" || ok "the log has no raw S3 identity output"
# shellcheck disable=SC1091
( source /opt/seaweedfs/monitoring-credentials.env
  code=$(curl -s -m 10 --cacert "$MONITORING_S3_CA" --aws-sigv4 aws:amz:us-east-1:s3 --user "$MONITORING_S3_ACCESS_KEY:$MONITORING_S3_SECRET_KEY" -o /dev/null -w '%{http_code}' "$MONITORING_S3_ENDPOINT/")
  [ "$code" = 200 ] ) && ok "the monitoring credentials file's S3 endpoint and CA work" || bad "the monitoring credentials file's S3 endpoint or CA doesn't work"
v=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' install-seaweedfs)
[ -n "$v" ] && [ "$(state_value SCRIPT_VERSION)" = "$v" ] && ok "S16: .install-state records SCRIPT_VERSION=$v" || bad "S16: .install-state has SCRIPT_VERSION='$(state_value SCRIPT_VERSION)'"
hold_smb admin "$P1"; sp=$(smb_pid); ns=$(nfs_started)
cf=$(md5 /opt/caddy/Caddyfile); st=$(started)
inst SWFS_PASSWORD=$P1 S3_ACCESS_KEY=$K1 S3_SECRET_KEY=$S1 && ok "identical re-run" || { bad "identical re-run"; show; }
[ "$(md5 /opt/caddy/Caddyfile)" = "$cf" ] && ok "an identical re-run leaves the Caddyfile alone" || bad "an identical re-run changed the Caddyfile"
[ "$(started)" = "$st" ] && ! grep -q "restarting seaweed-caddy" "$W/o" && ok "an identical re-run doesn't restart Caddy" || bad "an identical re-run restarted Caddy"
[ "$(smb_pid)" = "$sp" ] && ok "S15: an identical re-run doesn't restart Samba" || bad "S15: Samba restarted ($sp, now $(smb_pid))"
[ "$(nfs_started)" = "$ns" ] && ok "S15: an identical re-run doesn't restart the NFS server" || bad "S15: the NFS server restarted"
end_smb && ok "S15: an SMB session open across the re-run still works" || { bad "S15: the open SMB session broke"; tail -3 "$W/hold/out"; }
grep -q 'Samba: no change' "$W/o" && grep -q 'NFS: no change' "$W/o" && ok "S15: the log says Samba and NFS were left alone" || bad "S15: the log doesn't say so"

echo "=== S15: a changed share and export reload and re-export, with no restart"
sp=$(smb_pid); ns=$(nfs_started)
inst SWFS_PASSWORD=$P1 S3_ACCESS_KEY=$K1 S3_SECRET_KEY=$S1 SWFS_USER=s15user S3_USER=admin NFS_CLIENTS="$IP" && ok "re-run with a new SMB user and NFS client" || { bad "re-run with a new SMB user and NFS client"; show; }
grep -q 'valid users = s15user' /etc/samba/smb.conf && grep -q "^/mnt/seaweed $IP(" /etc/exports && ok "smb.conf and /etc/exports changed" || bad "smb.conf or /etc/exports didn't change"
grep -q 'Samba: configuration changed, reloading' "$W/o" && [ "$(smb_pid)" = "$sp" ] && ok "S15: Samba reloaded, not restarted" || bad "S15: Samba wasn't reloaded in place ($sp, now $(smb_pid))"
grep -q 'NFS: export changed, re-exporting' "$W/o" && [ "$(nfs_started)" = "$ns" ] && ok "S15: the export changed without an NFS restart" || bad "S15: NFS wasn't re-exported in place"
exportfs -v | grep -q "^/mnt/seaweed" && exportfs -v | grep -A1 '^/mnt/seaweed' | grep -q "$IP" && ok "S15: the new export is live" || bad "S15: the new export isn't live: $(exportfs -v | tr '\n' ' ')"

echo "=== S15: a stopped NFS server is started"
systemctl stop "$(state_value NFS_SERVICE_NAME)"
inst SWFS_PASSWORD=$P1 S3_ACCESS_KEY=$K1 S3_SECRET_KEY=$S1 SWFS_USER=s15user S3_USER=admin NFS_CLIENTS="$IP" && ok "re-run with NFS stopped" || { bad "re-run with NFS stopped"; show; }
systemctl is-active --quiet "$(state_value NFS_SERVICE_NAME)" && grep -q 'NFS: not running' "$W/o" && ok "S15: the re-run started NFS" || bad "S15: NFS is still stopped"

echo "=== S15: a re-run that replaces the mount restarts Samba and NFS, which then serve the new one"
# Run seaweed-mount with a config the installer doesn't write, so its re-run recreates the container
sed -i 's/^\(    container_name: seaweed-mount\)$/\1\n    labels: [ci.s15=replace]/' /opt/seaweedfs/seaweedfs-compose.yaml
docker compose -f /opt/seaweedfs/seaweedfs-compose.yaml up -d seaweed-mount >/dev/null 2>&1
sp=$(smb_pid); ns=$(nfs_started)
inst SWFS_PASSWORD=$P1 S3_ACCESS_KEY=$K1 S3_SECRET_KEY=$S1 SWFS_USER=s15user S3_USER=admin NFS_CLIENTS="$IP" && ok "re-run that recreates seaweed-mount" || { bad "re-run that recreates seaweed-mount"; show; }
grep -q 'Samba: this run replaced the /mnt/seaweed mount' "$W/o" && grep -q 'NFS: this run replaced the /mnt/seaweed mount' "$W/o" && ok "S15: the log says the mount was replaced" || bad "S15: the replaced mount wasn't noticed"
[ "$(smb_pid)" != "$sp" ] && [ "$(nfs_started)" != "$ns" ] && ok "S15: Samba and the NFS server restarted" || bad "S15: a service kept serving the old mount"
[ "$(docker inspect -f '{{index .Config.Labels "ci.s15"}}' seaweed-mount 2>/dev/null)" = "" ] && findmnt -n -o FSTYPE /mnt/seaweed | tail -1 | grep -q '^fuse' && ok "S15: /mnt/seaweed is the new container's FUSE mount" || bad "S15: /mnt/seaweed isn't the new mount"
echo s15 > /mnt/seaweed/s15-replaced.txt
hold_smb s15user "$P1"
end_smb && grep -q 's15-replaced.txt' "$W/hold/out" && ok "S15: a new SMB session sees a file written to the new mount" || { bad "S15: SMB doesn't serve the new mount"; tail -4 "$W/hold/out"; }
exportfs -v | grep -q '^/mnt/seaweed' && ok "S15: NFS exports the new mount" || bad "S15: no NFS export after the restart"
rm -f /mnt/seaweed/s15-replaced.txt

echo "=== New password and keys (S3, S7), revoking a key (SC1), re-runs with no keys (S11)"
st=$(started)
inst SWFS_PASSWORD=$P2 S3_ACCESS_KEY=$K2 S3_SECRET_KEY=$S2 && ok "re-run with a new password and key" || { bad "re-run with a new password and key"; show; }
[ "$(started)" != "$st" ] && ok "a new password restarts Caddy" || bad "a new password didn't restart Caddy"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$P2" "https://$IP:8888/artifacts/"); [[ "$code" =~ ^[23] ]] && ok "the new password works" || bad "the new password got $code"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$P1" "https://$IP:8888/artifacts/"); [ "$code" = 401 ] && ok "the old password is refused" || bad "the old password got $code"
grep -q "$P1" "$LOG" && bad "the log still holds the old password" || ok "the log no longer holds the old password"
grep -qE "$K1|$S1" "$LOG" && bad "the log still holds the old S3 key" || ok "the log no longer holds the old S3 key"
[ "$(grep -c "API Key:  $K2" "$LOG")" = 1 ] && ok "the log has one credentials block, with the current key" || bad "the log doesn't have exactly one block with the current key"
[ "$(s3ls $K1 $S1)" = 200 ] && ok "a new key leaves the old one working" || bad "the old key stopped working before it was revoked"
inst SWFS_PASSWORD=$P2 S3_ACCESS_KEY=$K2 S3_SECRET_KEY=$S2 S3_REVOKE_ACCESS_KEYS=$K1 && ok "re-run revoking the old key" || { bad "re-run revoking the old key"; show; }
[ "$(s3ls $K1 $S1)" = 403 ] && ok "the revoked key is refused" || bad "the revoked key got $(s3ls $K1 $S1)"
[ "$(s3ls $K2 $S2)" = 200 ] && ok "the current key still works" || bad "the current key got $(s3ls $K2 $S2)"
if inst SWFS_PASSWORD=$P2 S3_ACCESS_KEY=$K2 S3_SECRET_KEY=$S2 S3_REVOKE_ACCESS_KEYS=$K2; then bad "revoked the key it was given"
elif grep -q "names the key this run configures" "$W/o" && [ "$(s3ls $K2 $S2)" = 200 ]; then ok "refuses to revoke the key it was given, and the key still works"
else bad "the refusal to revoke its own key is wrong"; show; fi
n=$(s3keys)
inst SWFS_PASSWORD=$P2 && ok "re-run with no keys" || { bad "re-run with no keys"; show; }
grep -q "keeping the pair" "$W/o" && [ "$(s3keys)" = "$n" ] && ok "a re-run with no keys keeps the pair, and adds no key" || bad "a re-run with no keys added a key ($n before, $(s3keys) after)"
[ "$(s3ls $K2 $S2)" = 200 ] && ok "the kept key still works" || bad "the kept key got $(s3ls $K2 $S2)"

echo "=== A value Caddy can't parse (S8)"
cf=$(md5 /opt/caddy/Caddyfile); st=$(started)
if inst SWFS_PASSWORD=$P2 SWFS_USER='bad user'; then bad "exit 0 with a Caddyfile Caddy can't parse"
elif grep -q "Caddy rejected" "$W/o"; then ok "refuses a Caddyfile Caddy can't parse"
else bad "failed, but not on the Caddyfile"; show; fi
[ "$(md5 /opt/caddy/Caddyfile)" = "$cf" ] && [ "$(started)" = "$st" ] && ok "the running Caddy keeps its config" || bad "the running Caddy's config changed"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$IP:443/login"); [[ "$code" =~ ^[23] ]] && ok "the admin UI still answers" || bad "the admin UI answered $code"

echo "=== Custom Prometheus and Grafana ports (S4)"
inst SWFS_PASSWORD=$P2 PROMETHEUS_EXT_PORT=19090 GRAFANA_PORT=13000 && ok "re-run with custom monitoring ports" || { bad "re-run with custom monitoring ports"; show; }
# Some test images have no jq, so count the health fields.
targets=0 up=0
for _ in $(seq 1 12); do
  t=$(curl -s -m 5 "http://127.0.0.1:19090/api/v1/targets")
  targets=$(grep -o '"health":"' <<< "$t" | wc -l); up=$(grep -o '"health":"up"' <<< "$t" | wc -l)
  [ "$targets" -ge 3 ] && [ "$up" = "$targets" ] && break; sleep 10
done
[ "$targets" -ge 3 ] && [ "$up" = "$targets" ] && ok "every scrape target is up on custom ports" || bad "$up of $targets scrape targets up on custom ports"
grep -q 'url: http://prometheus:9090' /opt/monitoring/grafana/provisioning/datasources/datasources.yaml && ok "Grafana's datasource uses Prometheus' own port" || bad "Grafana's datasource uses the published port"

echo "=== A non-443 admin port (S6)"
inst SWFS_PASSWORD=$P2 SWFS_ADMIN_PORT=8443 && ok "re-run with admin port 8443" || { bad "re-run with admin port 8443"; show; }
r=$(curl -sk -m 10 -o /dev/null -w '%{redirect_url}' --resolve "filer.$HOST_FQDN:8888:127.0.0.1" "https://filer.$HOST_FQDN:8888/")
[ "$r" = "https://admin.$HOST_FQDN:8443/" ] && ok "the Filer's name redirects to the admin port" || bad "the Filer's name redirects to '$r'"
r=$(curl -sk -m 10 -o /dev/null -w '%{redirect_url}' "https://$IP:8888/")
[ "$r" = "https://$IP:8443/" ] && ok "the Filer's address redirects to the admin port" || bad "the Filer's address redirects to '$r'"

echo "=== A changed DEFAULT_FILER_DIR_NAME (S12)"
inst SWFS_PASSWORD=$P2 DEFAULT_FILER_DIR_NAME=other && grep -q "DEFAULT_FILER_DIR_NAME changed from 'artifacts' to 'other'" "$W/o" \
  && ok "warns when DEFAULT_FILER_DIR_NAME changes" || { bad "no warning when DEFAULT_FILER_DIR_NAME changes"; show; }
inst SWFS_PASSWORD=$P2 && ok "re-run with the defaults" || { bad "re-run with the defaults"; show; }

echo "=== A changed SWFS_USER (S2)"
id swfsa >/dev/null 2>&1 && userdel swfsa
id keepme >/dev/null 2>&1 || useradd -M -s /sbin/nologin keepme
inst SWFS_PASSWORD=$P2 SWFS_USER=swfsa S3_USER=admin ENABLE_MONITORING=false && ok "re-run as SWFS_USER=swfsa" || { bad "re-run as SWFS_USER=swfsa"; show; }
inst SWFS_PASSWORD=$P2 SWFS_USER=keepme S3_USER=admin ENABLE_MONITORING=false && ok "re-run as SWFS_USER=keepme, an existing account" || { bad "re-run as SWFS_USER=keepme"; show; }
id swfsa >/dev/null 2>&1 && bad "the account the installer created is left behind" || ok "the account the installer created is removed when SWFS_USER changes"
./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
id keepme >/dev/null 2>&1 && ok "uninstall keeps an account the installer didn't create" || bad "uninstall deleted keepme"
userdel keepme >/dev/null 2>&1

echo "=== A bare push (S1)"
mkdir -p "$W/reg"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" -keyout "$W/reg/r.key" -out "$W/reg/r.crt" >/dev/null 2>&1
docker rm -f s02-registry >/dev/null 2>&1
# image_pull_push.sh restarts Docker once it trusts the registry's certificate, so the registry has to come back.
if docker run -d --name s02-registry --restart=unless-stopped -p 5000:5000 -v "$W/reg:/certs:ro" -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/r.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/r.key registry:2 >/dev/null 2>&1; then
  sleep 3
  ENABLE_MONITORING=false ./install-seaweedfs push -registry "$IP:5000" ci ci > "$W/o" 2>&1 && ok "a bare push" || { bad "a bare push"; show; }
  cat=$(curl -sk -m 10 "https://$IP:5000/v2/_catalog")
  [[ "$cat" == *chrislusf/seaweedfs* && "$cat" == *caddy* ]] && ok "the images reach the registry" || bad "the registry has $cat"
  [ ! -e /opt/seaweedfs/.install-state ] && ok "a push records no install state" || bad "a push created the install-state file"
  docker rm -f s02-registry >/dev/null 2>&1
else
  bad "couldn't start a test registry"
fi

echo "=== A firewall rule someone else added (S9)"
if command -v ufw >/dev/null 2>&1 && ! systemctl is-active -q firewalld 2>/dev/null; then
  ufw allow 22/tcp >/dev/null; ufw allow 443/tcp comment 'someone-elses' >/dev/null; ufw --force enable >/dev/null
  inst SWFS_PASSWORD=$P2 ENABLE_MONITORING=false && ok "install with UFW on" || { bad "install with UFW on"; show; }
  grep -q "Port preflight passed" "$W/o" && ok "an install after a push still runs the port preflight" || bad "an install after a push skipped the port preflight"
  grep -E '^UFW_ADDED_PORTS=' /opt/seaweedfs/.install-state | grep -qw '443/tcp' && bad "claims the existing 443 rule" || ok "doesn't claim the existing 443 rule"
  ./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
  ufw show added | grep -q "^ufw allow 443/tcp comment 'someone-elses'" && ok "uninstall keeps the existing 443 rule" || bad "uninstall deleted the existing 443 rule"
  ufw --force disable >/dev/null; ufw --force reset >/dev/null 2>&1
else
  inst SWFS_PASSWORD=$P2 ENABLE_MONITORING=false && ok "install" || { bad "install"; show; }
  grep -q "Port preflight passed" "$W/o" && ok "an install after a push still runs the port preflight" || bad "an install after a push skipped the port preflight"
  ./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; show; }
  skip "the UFW case: this host has no UFW, or runs firewalld"
fi
[ -z "$(docker ps -q --filter name=seaweed 2>/dev/null)" ] && ok "no containers left" || bad "containers left behind"
echo "=== exit $fail"; exit $fail
