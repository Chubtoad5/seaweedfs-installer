#!/bin/bash
# The real installer on a throwaway host, as root, from the repo root: install, same-settings re-run, uninstall.
# The admin password is spec 21's full test password: a space and every symbol, *, ? and [ among them, which the
# image's own entrypoint split and globbed (S17), and $, \, quotes, & ; | and # that compose changed (S19, S20). It must
# log in at the Admin UI, the Filer, SMB and Grafana, and a changed one must reach Grafana (S21). mini.options, which
# holds it, must stay private across a restart (S18).
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
W=$(mktemp -d); cd "$W" || exit 1
cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
# shellcheck source=../vectors.bash
source "$REPO/tests/vectors.bash"
load_vectors "$REPO/tests/password-vectors.txt"
P=${VEC[full]}
export HOST_FQDN=files.test.lab SWFS_PASSWORD=$P S3_ACCESS_KEY=aaaa1111bbbb2222 S3_SECRET_KEY=cccc3333dddd4444eeee5555ffff6666 DEBUG=0
IP=$(hostname -I | awk '{print $1}')
# Files a glob in the password could match, in the folder the installer runs from
touch "$W/Aa1-glob-bait" "$W/Aa1 x" "$W/~"
# within <seconds> <command...>: true once the command is, checking every 3 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
# admin_login <password>: the Admin UI's own form login, through Caddy, CSRF token and all. True when it lets us in.
admin_login() {
  local cj tok r; cj=$(mktemp)
  tok=$(curl -sk -m 10 -c "$cj" "https://$IP:443/login" | grep -o 'name="csrf_token" value="[^"]*"' | sed 's/.*value="//; s/"$//')
  r=$(curl -sk -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' -b "$cj" -c "$cj" --data-urlencode "csrf_token=$tok" \
        --data-urlencode "username=admin" --data-urlencode "password=$1" "https://$IP:443/login")
  rm -f "$cj"
  [[ -n "$tok" && "$r" == 303* && "$r" != *error=* ]]
}
weed_pid() { docker inspect -f '{{.State.Pid}}' seaweed-mini 2>/dev/null; }
MO=/opt/seaweedfs/mini/mini.options
# private <when>: mini.options holds the password, and neither nobody nor the image's seaweed uid (1000 on most VMs, the
# first login user) can read it
private() {
  local uid
  # weed quotes a value with a space in it, Go style: admin.password="Aa1 !\"#..."
  local q; q=$(python3 -I -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$P")
  grep -qxF -e "admin.password=$P" -e "admin.password=\"$P\"" -e "admin.password=$q" -- "$MO" 2>/dev/null && ok "$1: mini.options holds the whole password" || bad "$1: mini.options doesn't hold the whole password"
  for uid in 65534 "$(docker exec seaweed-mini id -u seaweed 2>/dev/null || echo 1000)"; do
    if setpriv --reuid="$uid" --regid="$uid" --clear-groups cat "$MO" >/dev/null 2>&1; then
      bad "$1: uid $uid can read mini.options ($(stat -c '%a' /opt/seaweedfs 2>/dev/null) on /opt/seaweedfs)"
    else ok "$1: uid $uid can't read mini.options"; fi
  done
}
# Rocky's image has Cockpit's socket on 9090, which Prometheus needs. The installer should refuse and say how to free it.
if systemctl is-active -q cockpit.socket 2>/dev/null; then
  if ./install-seaweedfs install >"$W/o" 2>&1; then bad "installed with 9090 taken"
  elif grep -q "disable --now cockpit.socket" "$W/o"; then ok "refuses while Cockpit holds 9090, and says how to free it"
  else bad "the refusal doesn't say how to free 9090"; tail -6 "$W/o" | cut -c1-170; fi
  systemctl disable --now cockpit.socket >/dev/null 2>&1
fi
./install-seaweedfs install >"$W/o" 2>&1 && ok "install, with a space, *, ? and [ in the password" || { bad "install"; tail -6 "$W/o" | cut -c1-170; }
for c in seaweed-mini seaweed-caddy; do [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && ok "$c is running" || bad "$c isn't running"; done
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$IP:443/login"); [[ "$code" =~ ^[23] ]] && ok "the admin UI answers" || bad "the admin UI answered $code"
within 60 admin_login "$P" && ok "S17: the Admin UI's login takes the whole password" || bad "S17: the Admin UI's login refuses the whole password"
admin_login Aa1 && bad "S17: the Admin UI's login takes the password's first word" || ok "S17: the Admin UI's login refuses the first word alone"
# S19, S20: what compose delivered, read from the running containers (some test images have no jq): weed's command line,
# and Grafana's environment
margs=$(tr '\0' '\n' < "/proc/$(weed_pid)/cmdline" 2>/dev/null)
[ "$(grep -A1 -xF -- '-admin.password' <<< "$margs" | tail -n 1)" = "$P" ] \
  && ok "S19: weed got the admin password exactly from compose" || bad "S19: weed got a different admin password from compose"
grep -qxF -- '-webdav=false' <<< "$margs" && ok "S19: weed got all its arguments, -webdav=false included" || bad "S19: weed's command lost arguments"
genv=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' grafana 2>/dev/null | sed -n 's/^GF_SECURITY_ADMIN_PASSWORD=//p')
[ "$genv" = "$P" ] && ok "S20: Grafana got the password exactly from compose" || bad "S20: Grafana got a different password from compose"
grep -q 'basic_auth argon2id {' /opt/caddy/Caddyfile && ok "S23: Caddy's login is argon2id" || bad "S23: Caddy's login isn't argon2id"
# smb <password>: smbclient in an Alpine container lists the share as admin, the password in its environment (PASSWD)
smb() { docker run --rm --network host -e PASSWD="$1" alpine:3.20 sh -c "apk add -q --no-cache samba-client >/dev/null 2>&1 && smbclient -m SMB3 //$IP/artifacts -U admin -c ls" >/dev/null 2>&1; }
smb "$P" && ok "S22: SMB takes the password" || bad "S22: SMB refuses the password"
c=$(curl -sk -m 20 --aws-sigv4 aws:amz:us-east-1:s3 --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" -o /dev/null -w '%{http_code}' "https://$IP:8333/")
[ "$c" = 200 ] && ok "S24: S3 takes the keys" || bad "S24: S3 answered $c"
pid=$(weed_pid)
n=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -cxF -- "$P")
[ "$n" = 1 ] && ok "S17: weed's command line holds the password as one argument" || bad "S17: weed's command line holds the whole password $n times, not once (split by an entrypoint?)"
[ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$(docker exec seaweed-mini id -u seaweed 2>/dev/null)" ] && ok "S17: weed runs as the image's seaweed user, as before" || bad "S17: weed runs as uid $(stat -c %u "/proc/$pid" 2>/dev/null)"
[ "$(stat -c %a /opt/seaweedfs)" = 700 ] && ok "S18: /opt/seaweedfs is mode 700" || bad "S18: /opt/seaweedfs is mode $(stat -c %a /opt/seaweedfs)"
private "S18, after the install"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$SWFS_PASSWORD" "https://$IP:8888/artifacts/"); [[ "$code" =~ ^[23] ]] && ok "the Filer answers" || bad "the Filer answered $code"
grafana_as() { [ "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$1" "https://$IP:3000/api/user")" = 200 ]; }
grafana() { grafana_as "$P"; }
within 90 grafana && ok "Grafana takes the whole password" || bad "Grafana refuses the whole password"
# weed rewrites mini.options at every start, with mode 644
before=$(stat -c %Y.%y "$MO" 2>/dev/null); sleep 1
docker restart seaweed-mini >/dev/null 2>&1 && ok "docker restart seaweed-mini" || bad "docker restart seaweed-mini"
rewritten() { [ "$(stat -c %Y.%y "$MO" 2>/dev/null)" != "$before" ]; }
within 60 rewritten && ok "S18: weed rewrote mini.options as it started" || bad "S18: mini.options wasn't rewritten after the restart"
private "S18, after the restart"
within 60 admin_login "$P" && ok "S17: after the restart, the Admin UI's login takes the whole password" || bad "S17: after the restart, the Admin UI's login refuses the whole password"
./install-seaweedfs install >"$W/o" 2>&1 && ok "same-settings re-run" || { bad "re-run"; tail -6 "$W/o" | cut -c1-170; }
# S21: a changed password reaches Grafana, and every other surface. Spaces at either end, which Grafana's reset keeps.
P2=${VEC[ends]}
SWFS_PASSWORD=$P2 ./install-seaweedfs install >"$W/o" 2>&1 && ok "a re-run with a new password" || { bad "a re-run with a new password"; tail -6 "$W/o" | cut -c1-170; }
within 90 grafana_as "$P2" && ok "S21: Grafana takes the new password" || bad "S21: Grafana refuses the new password"
grafana_as "$P" && bad "S21: Grafana still takes the old password" || ok "S21: Grafana refuses the old password"
within 60 admin_login "$P2" && ok "the Admin UI takes the new password" || bad "the Admin UI refuses the new password"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$P2" "https://$IP:8888/artifacts/"); [[ "$code" =~ ^[23] ]] && ok "the Filer takes the new password" || bad "the Filer answered $code"
smb "$P2" && ok "SMB takes the new password" || bad "SMB refuses the new password"
./install-seaweedfs uninstall >"$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
[ -z "$(docker ps -q --filter name=seaweed 2>/dev/null)" ] && ok "no containers left" || bad "containers left behind"
[ ! -e /opt/seaweedfs ] && ok "/opt/seaweedfs is gone" || bad "/opt/seaweedfs is still there"
echo "=== exit $fail"; exit $fail
