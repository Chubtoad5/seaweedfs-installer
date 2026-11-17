#!/bin/bash
# Spec 24: object-tech-ops passes its own SWFS_IMAGE, chrislusf/seaweedfs:4.30, which wins over the installer's 4.54 pin.
# On 4.30 nothing listens on 12535 by default, so the Admin UI works only because mini gets -admin.port=12535 (S31). The
# real installer on a throwaway host, as root, from the repo root: install with the 4.30 image, log in at the Admin UI
# through Caddy with the whole password, check weed got the port flag, uninstall. Monitoring, SMB, NFS and MQ off.
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
IMG=chrislusf/seaweedfs:4.30
export HOST_FQDN=files.test.lab SWFS_PASSWORD=$P SWFS_IMAGE=$IMG DEBUG=0
export ENABLE_MONITORING=false ENABLE_SMB=false ENABLE_NFS=false ENABLE_MQ=false
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 3)); do "$@" && return 0; sleep 3; done; "$@"; }
admin_login() { # the Admin UI's own form login through Caddy, CSRF token and all; true when it lets us in
  local cj tok r; cj=$(mktemp)
  tok=$(curl -sk -m 10 -c "$cj" "https://$IP:443/login" | grep -o 'name="csrf_token" value="[^"]*"' | sed 's/.*value="//; s/"$//')
  r=$(curl -sk -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' -b "$cj" -c "$cj" --data-urlencode "csrf_token=$tok" \
        --data-urlencode "username=admin" --data-urlencode "password=$1" "https://$IP:443/login")
  rm -f "$cj"; [[ -n "$tok" && "$r" == 303* && "$r" != *error=* ]]; }
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true

./install-seaweedfs install > "$W/o" 2>&1 && ok "install with SWFS_IMAGE=$IMG" || { bad "install with SWFS_IMAGE=$IMG"; tail -8 "$W/o" | cut -c1-170; }
[ "$(docker inspect -f '{{.Config.Image}}' seaweed-mini 2>/dev/null)" = "$IMG" ] && ok "seaweed-mini runs $IMG, the caller's image" || bad "seaweed-mini runs $(docker inspect -f '{{.Config.Image}}' seaweed-mini 2>/dev/null)"
margs=$(tr '\0' '\n' < "/proc/$(docker inspect -f '{{.State.Pid}}' seaweed-mini 2>/dev/null)/cmdline" 2>/dev/null)
grep -qxF -- '-admin.port=12535' <<< "$margs" && ok "S31: weed got -admin.port=12535" || bad "S31: weed's command line has no -admin.port=12535"
code=$(docker exec seaweed-mini curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost:12535/login 2>/dev/null)
[[ "$code" =~ ^[23] ]] && ok "S31: 4.30's Admin UI answers on 12535" || bad "S31: 4.30's Admin UI answered $code on 12535"
within 60 admin_login "$P" && ok "S31: through Caddy, 4.30's Admin UI login takes the whole password" || bad "S31: through Caddy, 4.30's Admin UI login refuses the whole password"
admin_login Aa1 && bad "S17: 4.30's Admin UI login takes the password's first word" || ok "S17: 4.30's Admin UI login refuses the first word alone"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$IP:443/"); [[ "$code" =~ ^[23] ]] && ok "S31: the landing page's login gate answers ($code)" || bad "S31: the landing page answered $code"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$P" "https://$IP:8888/artifacts/"); [[ "$code" =~ ^[23] ]] && ok "the Filer answers" || bad "the Filer answered $code"
./install-seaweedfs uninstall > "$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
[ -z "$(docker ps -q --filter name=seaweed 2>/dev/null)" ] && ok "no containers left" || bad "containers left behind"
echo "=== exit $fail"; exit $fail
