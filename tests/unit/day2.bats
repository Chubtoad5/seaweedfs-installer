#!/usr/bin/env bats
# The Day-2 fixes (v1.1.0), function by function, with stubs. Tests that write under /opt or /etc run only as root
# in a container, as CI's unit tier does, so they can't touch a real host.
load ../helpers

setup() {
  setup_stubs
  load_script install-seaweedfs
  T=$(mktemp -d)
  STATE_FILE=$T/state LOG_FILE=$T/install.log
  stub sleep
}

in_container() {
  [[ $EUID -eq 0 && ( -f /run/.containerenv || -f /.dockerenv ) ]] || skip "writes under /opt or /etc: root in a container only"
}

# --- S10: MGMT_IP ---

@test "S10: install and join refuse an empty, garbage or IPv6 MGMT_IP" {
  for mode in INSTALL_MODE JOIN_MODE; do
    INSTALL_MODE=0 JOIN_MODE=0
    printf -v "$mode" 1
    for ip in "" "garbage" "fe80::1" "192.168.1.300"; do
      MGMT_IP=$ip
      run mgmt_ip_ok
      [ "$status" -ne 0 ]
    done
    MGMT_IP=10.0.0.5
    mgmt_ip_ok
  done
}

@test "S10: save and uninstall don't need MGMT_IP" {
  INSTALL_MODE=0 JOIN_MODE=0 MGMT_IP=""
  SAVE_MODE=1; mgmt_ip_ok
  SAVE_MODE=0 UNINSTALL_MODE=1; mgmt_ip_ok
}

# --- S8: Caddy has to be serving ---

@test "S8: verify_caddy passes when Caddy runs and answers" {
  stub docker 'echo running'
  stub curl 'echo 200'
  verify_caddy
}

@test "S8: verify_caddy fails, with Caddy's log, when the container keeps restarting" {
  stub docker '[[ "$1" == inspect ]] && echo restarting; [[ "$1" == logs ]] && echo "Error: adapting config"; exit 0'
  stub curl 'echo 000'
  run verify_caddy
  [ "$status" -eq 1 ]
  [[ "$output" == *"container: restarting"* ]]
  [[ "$output" == *"adapting config"* ]]
  [[ "$output" == *"didn't start serving"* ]]
}

@test "S8: verify_caddy waits for a slow start" {
  echo 0 > "$T/n"
  stub docker 'n=$(cat '"$T"'/n); echo $((n + 1)) > '"$T"'/n; if [ "$n" -lt 4 ]; then echo restarting; else echo running; fi'
  stub curl 'echo 302'
  verify_caddy
  [ "$(cat "$T/n")" -ge 5 ]
}

@test "S8: verify_caddy treats a 502 as not serving yet" {
  stub docker 'echo running'
  stub curl 'echo 502'
  run verify_caddy
  [ "$status" -eq 1 ]
}

@test "S8: a failed Caddy restart is an error" {
  stub docker '[[ "$1" == ps ]] && echo seaweed-caddy; [[ "$1" == restart ]] && exit 1; exit 0'
  run restart_if_changed seaweed-caddy aaa bbb
  [ "$status" -ne 0 ]
  restart_if_changed seaweed-caddy aaa aaa
}

# --- generate_caddyfile: S3, S6, S7, S8 ---

caddy_stub() { # docker: hash-password prints a new hash each call, validate exits $VALIDATE_RC
  echo 0 > "$T/hashes"
  stub docker 'case "$*" in
    *hash-password*) cat >/dev/null; n=$(cat '"$T"'/hashes); echo $((n + 1)) > '"$T"'/hashes; echo "\$argon2id\$v=19\$m=1,t=1,p=1\$c2FsdA\$hash$n" ;;
    *validate*) exit ${VALIDATE_RC:-0} ;;
  esac'
}

@test "S3: the same password reuses the stored hash, so the Caddyfile doesn't change" {
  in_container
  rm -rf /opt/caddy; caddy_stub
  SWFS_PASSWORD=pw1 MGMT_IP=10.0.0.5
  generate_caddyfile
  first=$(md5sum < /opt/caddy/Caddyfile)
  generate_caddyfile
  [ "$(md5sum < /opt/caddy/Caddyfile)" = "$first" ]
  [ "$(cat "$T/hashes")" = 1 ]
}

@test "S3: a new password is hashed again" {
  in_container
  rm -rf /opt/caddy; caddy_stub
  SWFS_PASSWORD=pw1 MGMT_IP=10.0.0.5
  generate_caddyfile
  SWFS_PASSWORD=pw2
  generate_caddyfile
  [ "$(cat "$T/hashes")" = 2 ]
  grep -q 'hash1' /opt/caddy/Caddyfile
  # The stored fingerprint follows the new password, so pw2 now reuses hash1.
  generate_caddyfile
  [ "$(cat "$T/hashes")" = 2 ]
}

@test "S3: the password isn't on openssl's command line" {
  stub openssl 'cat > /dev/null; echo "(stdin)= abc"'
  SWFS_PASSWORD=sekrit-pw
  auth_fingerprint 'somehash'
  ! grep -q sekrit-pw "$STUB_LOG"
}

@test "S7: the Caddyfile and the stored hash are mode 600, even when an older release made them 644" {
  in_container
  rm -rf /opt/caddy; mkdir -p /opt/caddy; caddy_stub
  : > /opt/caddy/Caddyfile; chmod 644 /opt/caddy/Caddyfile
  SWFS_PASSWORD=pw1 MGMT_IP=10.0.0.5
  generate_caddyfile
  [ "$(stat -c %a /opt/caddy/Caddyfile)" = 600 ]
  [ "$(stat -c %a /opt/caddy/.auth-hash)" = 600 ]
  [ ! -e /opt/caddy/Caddyfile.new ]
}

@test "S6: the Filer redirects carry a non-443 admin port, and the default renders as before" {
  in_container
  rm -rf /opt/caddy; caddy_stub
  SWFS_PASSWORD=pw1 MGMT_IP=10.0.0.5 SWFS_ADMIN_FQDN=admin.x.lab
  SWFS_ADMIN_PORT=8443
  generate_caddyfile
  grep -qF 'redir @isDomain https://admin.x.lab:8443 permanent' /opt/caddy/Caddyfile
  grep -qF 'redir https://{host}:8443 permanent' /opt/caddy/Caddyfile
  SWFS_ADMIN_PORT=443
  generate_caddyfile
  grep -qF 'redir @isDomain https://admin.x.lab permanent' /opt/caddy/Caddyfile
  grep -qF 'redir https://{host} permanent' /opt/caddy/Caddyfile
}

@test "S8: a Caddyfile Caddy rejects stops the run, and the old one stays" {
  in_container
  rm -rf /opt/caddy; caddy_stub
  SWFS_PASSWORD=pw1 MGMT_IP=10.0.0.5
  generate_caddyfile
  before=$(md5sum < /opt/caddy/Caddyfile)
  SWFS_USER='bad user' VALIDATE_RC=1
  export VALIDATE_RC
  run generate_caddyfile
  [ "$status" -eq 1 ]
  [[ "$output" == *"Caddy rejected"* ]]
  [ "$(md5sum < /opt/caddy/Caddyfile)" = "$before" ]
  [ ! -e /opt/caddy/Caddyfile.new ]
}

# --- S4, S5: monitoring configs ---

@test "S4: custom Prometheus and Grafana ports leave in-network addresses on the containers' own ports" {
  in_container
  rm -rf /opt/monitoring; mkdir -p /opt/monitoring/prometheus /opt/monitoring/grafana/provisioning/datasources
  PROMETHEUS_EXT_PORT=19090 GRAFANA_PORT=13000
  generate_prometheus_ext_config
  generate_grafana_datasources
  grep -qF '"localhost:9090"' /opt/monitoring/prometheus/prometheus.yml
  grep -qF '"grafana:3000"' /opt/monitoring/prometheus/prometheus.yml
  grep -qF 'url: http://prometheus:9090' /opt/monitoring/grafana/provisioning/datasources/datasources.yaml
  ! grep -qE '19090|13000' /opt/monitoring/prometheus/prometheus.yml /opt/monitoring/grafana/provisioning/datasources/datasources.yaml
}

@test "S5: the monitoring credentials name Caddy's TLS S3 port and its CA" {
  in_container
  mkdir -p /opt/seaweedfs
  MGMT_IP=10.0.0.5 SWFS_S3_PORT=18333 S3_ACCESS_KEY=k S3_SECRET_KEY=s
  write_monitoring_credentials
  grep -qx 'MONITORING_S3_ENDPOINT=https://10.0.0.5:18333' /opt/seaweedfs/monitoring-credentials.env
  grep -qx 'MONITORING_S3_CA=/opt/caddy/data/caddy/pki/authorities/local/root.crt' /opt/seaweedfs/monitoring-credentials.env
  [ "$(stat -c %a /opt/seaweedfs/monitoring-credentials.env)" = 600 ]
}

# --- S7: the log keeps only the latest credentials ---

@test "S7: an old unmarked log loses its credential lines and keeps the rest" {
  cat > "$LOG_FILE" <<'LOG'
  Creating Caddyfile...
To mount SMB share from Windows: 'net use Z: \\h\artifacts OldPass /USER:admin /PERSISTENT:YES'
  Username: admin
  Password: OldPass
  API Key:  oldkey123
  API Secret: oldsecret456
  Grafana:            https://grafana.x:3000  (user: admin / pass: OldPass)
      "accessKey": "oldkey123",
      "secretKey": "oldsecret456",
  Port preflight passed
LOG
  scrub_logged_credentials
  ! grep -qE 'OldPass|oldkey123|oldsecret456' "$LOG_FILE"
  grep -q 'Creating Caddyfile' "$LOG_FILE"
  grep -q 'Port preflight passed' "$LOG_FILE"
  grep -q 'Username: admin' "$LOG_FILE"
}

@test "S7: re-runs leave one credentials block, the latest, in the format key adoption reads" {
  MGMT_IP=10.0.0.5 ENABLE_MONITORING=true
  SWFS_PASSWORD=pw1 S3_ACCESS_KEY=key1 S3_SECRET_KEY=sec1
  generate_outputs > /dev/null
  SWFS_PASSWORD=pw2 S3_ACCESS_KEY=key2 S3_SECRET_KEY=sec2
  generate_outputs > /dev/null
  ! grep -qE 'pw1|key1|sec1' "$LOG_FILE"
  [ "$(grep -c '^# BEGIN credentials$' "$LOG_FILE")" = 1 ]
  [ "$(grep -c '^# END credentials$' "$LOG_FILE")" = 1 ]
  grep -qx '  API Key:  key2' "$LOG_FILE"
  grep -qx '  API Secret: sec2' "$LOG_FILE"
  [ "$(stat -c %a "$LOG_FILE")" = 600 ]
}

@test "S7: weed shell output is masked for the log" {
  out=$(printf '%s\n' '"accessKey": "abc123",' '"secretKey": "def456"' 's3.configure -access_key=abc123 -secret_key=def456' | mask_s3_keys)
  [[ "$out" != *abc123* && "$out" != *def456* ]]
  [[ "$out" == *'"accessKey": "****"'* ]]
}

# --- S9: UFW ---

ufw_stub() { # ufw_stub "<rules ufw show added lists>"
  printf '%s\n' "Added user rules (see 'ufw status' for running firewall):" $1 > "$T/ufw-added"
  stub ufw 'case "$1" in status) echo "Status: active" ;; show) cat '"$T"'/ufw-added ;; esac; exit 0'
  stub systemctl 'exit 3'
  # An installed host has a state file. Without one, get_state returns 1, and bats takes that as a failure.
  : > "$STATE_FILE"
}

@test "S9: UFW: a rule that isn't there is added and claimed" {
  ufw_stub ""
  configure_firewall "443/tcp" false false
  called "ufw allow 443/tcp comment seaweedfs-installer"
  [ "$(get_state UFW_ADDED_PORTS)" = "443/tcp" ]
}

@test "S9: UFW: a rule someone else added is neither re-added nor claimed" {
  ufw_stub "ufw_allow_443/tcp_comment_'theirs'"
  sed -i 's/_/ /g' "$T/ufw-added"
  configure_firewall "443/tcp 8888/tcp" false false
  ! called "ufw allow 443/tcp"
  called "ufw allow 8888/tcp"
  [ "$(get_state UFW_ADDED_PORTS)" = "8888/tcp" ]
}

@test "S9: UFW: a rule an earlier run added stays claimed" {
  ufw_stub "ufw_allow_443/tcp_comment_'seaweedfs-installer'"
  sed -i 's/_/ /g' "$T/ufw-added"
  record_state UFW_ADDED_PORTS "443/tcp"
  configure_firewall "443/tcp" false false
  ! called "ufw allow 443/tcp"
  [ "$(get_state UFW_ADDED_PORTS)" = "443/tcp" ]
}

@test "S9: UFW: 443/tcp doesn't match a 4430/tcp rule" {
  ufw_stub "ufw_allow_4430/tcp"
  sed -i 's/_/ /g' "$T/ufw-added"
  configure_firewall "443/tcp" false false
  called "ufw allow 443/tcp"
}

# --- S2: a changed SWFS_USER ---

users_stub() { # users_stub "<accounts that exist>"
  printf '%s\n' $1 > "$T/users"
  stub id 'grep -qx "$1" '"$T"'/users'
  stub useradd 'echo "${@: -1}" >> '"$T"'/users'
  stub userdel 'grep -vx "$1" '"$T"'/users > '"$T"'/u2; mv '"$T"'/u2 '"$T"'/users'
  stub smbpasswd
  stub getent 'exit 2'
}

@test "S2: a new user is created and recorded as ours" {
  users_stub ""
  SWFS_USER=swfsa ensure_swfs_user
  called "useradd -M -s /sbin/nologin swfsa"
  [ "$(get_state SWFS_USER_CREATED)" = true ]
  [ "$(get_state SWFS_USER_NAME)" = swfsa ]
}

@test "S2: an existing user is used and recorded as not ours" {
  users_stub "keepme"
  SWFS_USER=keepme ensure_swfs_user
  ! called "useradd"
  [ "$(get_state SWFS_USER_CREATED)" = false ]
}

@test "S2: changing from a user we created to an existing one removes ours, and doesn't claim the other" {
  users_stub ""
  SWFS_USER=swfsa ensure_swfs_user
  echo keepme >> "$T/users"
  SWFS_USER=keepme ensure_swfs_user
  called "smbpasswd -x swfsa"
  called "userdel swfsa"
  [ "$(get_state SWFS_USER_CREATED)" = false ]
  [ "$(get_state SWFS_USER_NAME)" = keepme ]
}

@test "S2: changing from an existing user to a new one leaves the existing account alone" {
  users_stub "keepme"
  SWFS_USER=keepme ensure_swfs_user
  SWFS_USER=swfsb ensure_swfs_user
  called "smbpasswd -x keepme"
  ! called "userdel"
  grep -qx keepme "$T/users"
  [ "$(get_state SWFS_USER_CREATED)" = true ]
  [ "$(get_state SWFS_USER_NAME)" = swfsb ]
}

@test "S2: a group of the same name is joined with -g" {
  users_stub ""
  stub getent 'exit 0'
  SWFS_USER=admin ensure_swfs_user
  called "useradd -M -s /sbin/nologin -g admin admin"
}

# --- S11 and SC1: S3 keys ---

@test "S11: with no keys passed, the recorded pair for this S3 user is kept" {
  record_state S3_ACCESS_KEY oldk; record_state S3_SECRET_KEY olds; record_state S3_KEYS_USER admin
  S3_USER=admin S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [ "$S3_ACCESS_KEY" = oldk ] && [ "$S3_SECRET_KEY" = olds ]
}

@test "S11: a passed key wins over the recorded pair" {
  record_state S3_ACCESS_KEY oldk; record_state S3_SECRET_KEY olds; record_state S3_KEYS_USER admin
  S3_USER=admin S3_ACCESS_KEY=newk S3_SECRET_KEY=news
  resolve_s3_keys
  [ "$S3_ACCESS_KEY" = newk ] && [ "$S3_SECRET_KEY" = news ]
}

@test "S11: a different S3 user, or no recorded pair, gets a new random pair" {
  record_state S3_ACCESS_KEY oldk; record_state S3_SECRET_KEY olds; record_state S3_KEYS_USER admin
  S3_USER=other S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [[ "$S3_ACCESS_KEY" =~ ^[0-9a-f]{16}$ && "$S3_SECRET_KEY" =~ ^[0-9a-f]{32}$ ]]
  rm -f "$STATE_FILE"
  S3_USER=admin S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [[ "$S3_ACCESS_KEY" =~ ^[0-9a-f]{16}$ ]]
}

old_log() { # an install log as releases before 1.1.0 wrote it: two runs, newest last
  printf '%s\n' '  API User: admin' '  API Key:  oldest1' '  API Secret: oldsec1' '  API User: admin' '  API Key:  newest2' '  API Secret: newsec2' > "$LOG_FILE"
}
mini_with_key() { # docker: seaweed-mini runs, its Filer answers ${FILER_CODE:-200}, and its S3 identities hold key $1
  stub docker 'case "$1 $3" in
    "ps "*) echo seaweed-mini ;;
    "exec curl") echo "'"${FILER_CODE:-200}"'" ;;
    "exec "*) [ -n "'"$1"'" ] && echo "      \"accessKey\": \"'"$1"'\"," ;;
  esac; exit 0'
}

@test "S11: an install from before 1.1.0 keeps the newest pair in its log, if this host has that key" {
  old_log; mini_with_key newest2
  S3_USER=admin S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [ "$S3_ACCESS_KEY" = newest2 ] && [ "$S3_SECRET_KEY" = newsec2 ]
  S3_USER=other S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [ "$S3_ACCESS_KEY" != newest2 ]
}

@test "S11: a log from another host is never used: no SeaweedFS here, or one without that key" {
  old_log
  stub docker 'exit 0'
  S3_USER=admin S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [[ "$S3_ACCESS_KEY" != newest2 && "$S3_ACCESS_KEY" =~ ^[0-9a-f]{16}$ ]]
  mini_with_key somethingelse
  S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [[ "$S3_ACCESS_KEY" != newest2 && "$S3_ACCESS_KEY" =~ ^[0-9a-f]{16}$ ]]
}

@test "S11: a SeaweedFS that doesn't answer isn't asked, so the run doesn't wait on it" {
  old_log
  FILER_CODE=000 mini_with_key newest2
  S3_USER=admin S3_ACCESS_KEY="" S3_SECRET_KEY=""
  resolve_s3_keys
  [[ "$S3_ACCESS_KEY" != newest2 ]]
  ! called "weed shell"
}

@test "SC1: revoking the key this run configures is refused" {
  S3_USER=admin S3_ACCESS_KEY=k1 S3_SECRET_KEY=s1 S3_REVOKE_ACCESS_KEYS="k0 k1"
  run resolve_s3_keys
  [ "$status" -eq 1 ]
  [[ "$output" == *"names the key this run configures (k1)"* ]]
  S3_REVOKE_ACCESS_KEYS="k0"
  resolve_s3_keys
}

# --- S12 ---

@test "S12: a changed DEFAULT_FILER_DIR_NAME warns, naming both" {
  record_state FILER_DIR_NAME artifacts
  DEFAULT_FILER_DIR_NAME=other
  run warn_filer_dir_change
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed from 'artifacts' to 'other'"* ]]
  DEFAULT_FILER_DIR_NAME=artifacts
  run warn_filer_dir_change
  [ -z "$output" ]
}

# --- S1: a bare push ---

push_setup() {
  base_dir=$T/work; mkdir -p "$base_dir/utilities"
  download_image_pull_push() { :; }
  printf '#!/bin/bash\necho "image_pull_push.sh $*" >> "$STUB_LOG"\n' > "$base_dir/utilities/image_pull_push.sh"
  chmod +x "$base_dir/utilities/image_pull_push.sh"
  stub docker
  AIR_GAPPED_MODE=0 PUSH_MODE=1 REGISTRY_MODE=1 REGISTRY_INFO=reg.x.lab:5000 REG_FQDN=reg.x.lab REG_PORT=5000 REG_USER=u REG_PASS=p
  ENABLE_MONITORING=false
}

@test "S1: a bare push pushes, and records nothing on this host" {
  push_setup
  PUSH_ONLY=1
  run_docker
  called "image_pull_push.sh -f $base_dir/utilities/images.txt push reg.x.lab:5000 u p"
  ! called "docker login"
  [ ! -e "$STATE_FILE" ]
}

@test "S1: install with push still logs in and records the registry" {
  push_setup
  PUSH_ONLY=0
  run_docker
  called "image_pull_push.sh -f $base_dir/utilities/images.txt push"
  called "docker login reg.x.lab:5000"
  [ "$(get_state REGISTRY_LOGIN)" = "reg.x.lab:5000" ]
}
