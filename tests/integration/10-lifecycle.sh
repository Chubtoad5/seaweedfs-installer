#!/bin/bash
# The real installer on a throwaway host, as root, from the repo root: install, same-settings re-run, uninstall.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
W=$(mktemp -d); cd "$W" || exit 1
cp "$REPO/install-seaweedfs" .; chmod +x install-seaweedfs
export HOST_FQDN=files.test.lab SWFS_PASSWORD=Test-Pass-1 S3_ACCESS_KEY=aaaa1111bbbb2222 S3_SECRET_KEY=cccc3333dddd4444eeee5555ffff6666 DEBUG=0
IP=$(hostname -I | awk '{print $1}')
# Rocky's image has Cockpit's socket on 9090, which Prometheus needs. The installer should refuse and say how to free it.
if systemctl is-active -q cockpit.socket 2>/dev/null; then
  if ./install-seaweedfs install >"$W/o" 2>&1; then bad "installed with 9090 taken"
  elif grep -q "disable --now cockpit.socket" "$W/o"; then ok "refuses while Cockpit holds 9090, and says how to free it"
  else bad "the refusal doesn't say how to free 9090"; tail -6 "$W/o" | cut -c1-170; fi
  systemctl disable --now cockpit.socket >/dev/null 2>&1
fi
./install-seaweedfs install >"$W/o" 2>&1 && ok "install" || { bad "install"; tail -6 "$W/o" | cut -c1-170; }
for c in seaweed-mini seaweed-caddy; do [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && ok "$c is running" || bad "$c isn't running"; done
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$IP:443/login"); [[ "$code" =~ ^[23] ]] && ok "the admin UI answers" || bad "the admin UI answered $code"
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -u "admin:$SWFS_PASSWORD" "https://$IP:8888/artifacts/"); [[ "$code" =~ ^[23] ]] && ok "the Filer answers" || bad "the Filer answered $code"
./install-seaweedfs install >"$W/o" 2>&1 && ok "same-settings re-run" || { bad "re-run"; tail -6 "$W/o" | cut -c1-170; }
./install-seaweedfs uninstall >"$W/o" 2>&1 && ok "uninstall" || { bad "uninstall"; tail -6 "$W/o" | cut -c1-170; }
[ -z "$(docker ps -q --filter name=seaweed 2>/dev/null)" ] && ok "no containers left" || bad "containers left behind"
echo "=== exit $fail"; exit $fail
