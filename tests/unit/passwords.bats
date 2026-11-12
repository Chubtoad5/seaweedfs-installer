#!/usr/bin/env bats
# Spec 21: any SWFS_PASSWORD works everywhere it goes (S19-S23), and S3 keys reach weed shell, Loki and the credentials
# file exactly or are refused (S24-S26). Every test password goes through each place, and the bytes that arrive are
# compared. Compose files are read back with PyYAML, with compose's $$ undone; the integration tier runs compose itself.
# These write under /opt, so they run only as root in a container, as CI's unit tier does.
load ../helpers
load ../vectors

setup() {
  [[ $EUID -eq 0 && ( -f /run/.containerenv || -f /.dockerenv ) ]] || skip "writes under /opt: root in a container only"
  setup_stubs
  load_script install-seaweedfs
  load_vectors
  T=$(mktemp -d)
  LOG_FILE=$T/install.log
  rm -rf /opt/seaweedfs /opt/monitoring /opt/caddy
  SWFS_USER=admin DEFAULT_FILER_DIR_NAME=artifacts ENABLE_MONITORING=false ENABLE_MQ=false ENABLE_SMB=false
  ENABLE_NFS=false CLUSTER_MODE=single PUSH_MODE=0 REGISTRY_MODE=0 MGMT_IP=10.0.0.5
  configure_fuse_conf() { :; }
  record_state() { :; }
  # docker: hash-password records its stdin and prints an argon2id hash; validate passes; exec records its stdin
  stub docker 'd=${STUB_LOG%/*}
case "$*" in
  *"hash-password --algorithm argon2id"*) cat > "$d/hash.stdin"; echo "\$argon2id\$v=19\$m=47104,t=1,p=1\$c2FsdA\$aGFzaA" ;;
  *"caddy validate"*) exit 0 ;;
  "exec -i grafana "*) cat > "$d/grafana.stdin" ;;
  "exec -i seaweed-mini "*) cat > "$d/weed.stdin"; cat "$d/weed.out" 2>/dev/null ;;
esac'
}
teardown() { rm -rf /opt/seaweedfs /opt/monitoring /opt/caddy; }

# yaml_get <file> <key or list index>...: the value at that path, as compose would see it ($$ undone)
yaml_get() { python3 -I -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2:]:
    v = v[int(k)] if isinstance(v, list) else v[k]
print(v.replace("$$", "$"), end="")' "$@"; }
# mini_command: seaweed-mini's command list, one item per line, as compose would see it
mini_command() { python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); [print(a.replace("$$", "$")) for a in d["services"]["seaweed-mini"]["command"]]' /opt/seaweedfs/seaweedfs-compose.yaml; }

@test "S19: every test password reaches weed's command exactly, as one argument" {
  local n
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    SWFS_PASSWORD=${VEC[$n]}
    private_dir /opt/seaweedfs
    generate_compose_file
    [ "$(yaml_get /opt/seaweedfs/seaweedfs-compose.yaml services seaweed-mini command 4)" = "${VEC[$n]}" ]
    [ "$(yaml_get /opt/seaweedfs/seaweedfs-compose.yaml services seaweed-mini command 3)" = "-admin.password" ]
  done
}
@test "S19: the arguments and their order are what the folded command gave compose, with tuning and cluster flags" {
  SWFS_PASSWORD=changeme VOLUME_INDEX=leveldb VOLUME_SIZE_LIMIT_MB=512 CLUSTER_MODE=cluster CLUSTER_REPLICATION=001
  CLUSTER_DC=dc1 CLUSTER_RACK=r1 CLUSTER_MASTER_GRPC_PORT=19333 CLUSTER_VOLUME_PORT=9340 CLUSTER_VOLUME_GRPC_PORT=19340
  private_dir /opt/seaweedfs
  generate_compose_file
  want='mini -admin.user admin -admin.password changeme -dir=/data -webdav=false -volume.index=leveldb -master.volumeSizeLimitMB=512 -ip=10.0.0.5 -master.defaultReplication=001 -dataCenter=dc1 -rack=r1 -master.port.grpc=19333 -volume.port=9340 -volume.port.grpc=19340'
  [ "$(mini_command | tr '\n' ' ')" = "$want " ]
}
@test "S20: Grafana's user line is quoted for compose too, so a $ in the name reaches Grafana as written" {
  ENABLE_MONITORING=true GRAFANA_IMAGE=grafana/grafana-oss:11.5.2 LOKI_IMAGE=grafana/loki:3.4.2 PROMETHEUS_EXT_IMAGE=prom/prometheus:v3.2.1
  SWFS_PASSWORD=changeme SWFS_USER='ad$min'
  mkdir -p /opt/monitoring
  generate_monitoring_compose >/dev/null
  got=$(python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); e = [x for x in d["services"]["grafana"]["environment"] if x.startswith("GF_SECURITY_ADMIN_USER=")]; print(e[0].split("=", 1)[1].replace("$$", "$"), end="")' /opt/monitoring/docker-compose.yml)
  [ "$got" = 'ad$min' ]
}
@test "S20: every test password reaches Grafana's environment exactly" {
  local n
  ENABLE_MONITORING=true GRAFANA_IMAGE=grafana/grafana-oss:11.5.2 LOKI_IMAGE=grafana/loki:3.4.2 PROMETHEUS_EXT_IMAGE=prom/prometheus:v3.2.1
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    SWFS_PASSWORD=${VEC[$n]}
    mkdir -p /opt/monitoring
    generate_monitoring_compose >/dev/null
    got=$(python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); e = [x for x in d["services"]["grafana"]["environment"] if x.startswith("GF_SECURITY_ADMIN_PASSWORD=")]; print(e[0].split("=", 1)[1].replace("$$", "$"), end="")' /opt/monitoring/docker-compose.yml)
    [ "$got" = "${VEC[$n]}" ]
  done
}
@test "S21: Grafana's password is reset, from stdin, only when it changed or isn't recorded, and never on a new database" {
  SWFS_PASSWORD=${VEC[full]}
  mkdir -p /opt/monitoring
  sync_grafana_password 0
  [ ! -e "$STUB_DIR/grafana.stdin" ]
  [ "$(stat -c %a /opt/monitoring/.grafana-auth)" = 600 ]
  ! grep -qF -- "${VEC[full]}" /opt/monitoring/.grafana-auth || false
  sync_grafana_password 1
  [ ! -e "$STUB_DIR/grafana.stdin" ]
  SWFS_PASSWORD=${VEC[ends]}
  sync_grafana_password 1
  [ "$(cat "$STUB_DIR/grafana.stdin")" = "${VEC[ends]}" ]
  called 'docker exec -i grafana grafana cli admin reset-admin-password --password-from-stdin'
  ! grep -qF -- "${VEC[ends]}" "$STUB_LOG" || false
  # An install from before the record: reset once, then not again
  rm -f /opt/monitoring/.grafana-auth "$STUB_DIR/grafana.stdin"
  sync_grafana_password 1
  [ -e "$STUB_DIR/grafana.stdin" ]
  rm -f "$STUB_DIR/grafana.stdin"
  sync_grafana_password 1
  [ ! -e "$STUB_DIR/grafana.stdin" ]
}
@test "S22: every test password reaches smbpasswd exactly, twice" {
  local n
  ENABLE_SMB=true ID=ubuntu AIR_GAPPED_MODE=0
  download_install_packages() { :; }; install_os_packages() { :; }; ensure_swfs_user() { :; }
  # It records its input, then fails, so run_smb stops there
  stub smbpasswd 'cat > "${STUB_LOG%/*}/smb.stdin"; exit 1'
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    SWFS_PASSWORD=${VEC[$n]}
    run run_smb
    [ "$(cat "$STUB_DIR/smb.stdin")" = "${VEC[$n]}"$'\n'"${VEC[$n]}" ]
  done
}
@test "S23: Caddy hashes each test password with argon2id from stdin, and the Caddyfile names argon2id" {
  local n
  SWFS_ADMIN_FQDN=a.lab SWFS_MASTER_FQDN=m.lab SWFS_FILER_FQDN=f.lab SWFS_S3_FQDN=s.lab SWFS_ADMIN_PORT=443
  SWFS_MASTER_PORT=9333 SWFS_FILER_PORT=8888 SWFS_S3_PORT=8333 SPLASH_REQUIRE_LOGIN=true CADDY_IMAGE=caddy:2.11.3
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    SWFS_PASSWORD=${VEC[$n]}
    rm -f /opt/caddy/.auth-hash
    generate_caddyfile >/dev/null
    [ "$(cat "$STUB_DIR/hash.stdin")" = "${VEC[$n]}" ]
    [ "$(grep -c 'basic_auth argon2id {' /opt/caddy/Caddyfile)" = 2 ]
    [ "$(grep -c "admin \$argon2id\\\$" /opt/caddy/Caddyfile)" = 2 ]
  done
  ! grep -q -- '--plaintext' "$STUB_LOG" || false
}
@test "S23: a bcrypt hash an earlier release stored is kept while the password is the same, with its basic_auth line" {
  SWFS_ADMIN_FQDN=a.lab SWFS_MASTER_FQDN=m.lab SWFS_FILER_FQDN=f.lab SWFS_S3_FQDN=s.lab SWFS_ADMIN_PORT=443
  SWFS_MASTER_PORT=9333 SWFS_FILER_PORT=8888 SWFS_S3_PORT=8333 SPLASH_REQUIRE_LOGIN=true CADDY_IMAGE=caddy:2.11.3
  SWFS_PASSWORD=changeme
  h='$2a$14$abcdefghijklmnopqrstuvABCDEFGHIJKLMNOPQRSTUVWXYZ01234'
  mkdir -p /opt/caddy
  printf 'hash=%s\nfingerprint=%s\n' "$h" "$(auth_fingerprint "$h")" > /opt/caddy/.auth-hash
  generate_caddyfile >/dev/null
  [ ! -e "$STUB_DIR/hash.stdin" ]
  [ "$(grep -c '^ *basic_auth {$' /opt/caddy/Caddyfile)" = 2 ]
  grep -qF "admin $h" /opt/caddy/Caddyfile
}
@test "S23: over 72 bytes with a Caddy that has no argon2id is refused, with a message that names the image" {
  stub docker 'case "$*" in *hash-password*) cat >/dev/null; exit 1 ;; esac'
  SWFS_PASSWORD=${VEC[long]}
  run caddy_hash caddy:2.10.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"over 72 bytes"* && "$output" == *"caddy:2.10.0"* ]]
}
@test "S24: the keys reach weed shell in quotes, by printf; a failure is weed's own line, or the key missing" {
  S3_ACCESS_KEY=AKIA1234abcd S3_SECRET_KEY='wJal+r/X=U.t_n-F' S3_USER=admin S3_REVOKE_ACCESS_KEYS=""
  die() { echo "DIE: $*"; exit 1; }
  # protojson spaces its output at random: two spaces here
  printf '{\n  "identities": [\n    {\n      "name": "failed-backups",\n      "accessKey":  "AKIA1234abcd",\n      "secretKey": "x"\n    }\n  ]\n}\n' > "$STUB_DIR/weed.out"
  run configure_s3_credentials
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/weed.stdin")" = 's3.configure -access_key="AKIA1234abcd" -secret_key="wJal+r/X=U.t_n-F" -user=admin -actions=Read,Write,List,Admin -apply=true' ]
  # weed configured nothing: the key isn't among the identities, though no line says error
  printf '{\n  "identities": [\n  ]\n}\n' > "$STUB_DIR/weed.out"
  run configure_s3_credentials
  [ "$status" -eq 1 ]
  [[ "$output" == *"S3 credential configuration failed"* ]]
  printf 'error: parse flags: bad\n' > "$STUB_DIR/weed.out"
  run configure_s3_credentials
  [ "$status" -eq 1 ]
  weed_shell_failed 'unknown command: s3.configur'
  weed_shell_failed 'E1112 20:01:02.123456 shell.go:1] failed'
  ! weed_shell_failed '      "name": "failed-backups",' || false
  ! weed_shell_failed '      "accessKey": "error123",' || false
}
@test "S24, S26: keys outside the rule, a bad user name and a bad password are refused before anything changes" {
  local k
  SWFS_PASSWORD=changeme
  for k in 'AK IA' ' AKIA' 'AK;IA' 'AK"IA' "AK'IA" 'AK\IA'; do
    S3_ACCESS_KEY=$k S3_SECRET_KEY=abc
    run check_secrets
    [ "$status" -eq 1 ]
    [[ "$output" == *"S3_ACCESS_KEY can't contain"* && "$output" == *"Nothing has been changed"* ]]
  done
  for k in 'ab c' 'ab;c' 'ab"c' "ab'c" 'ab\c'; do
    S3_ACCESS_KEY=AKIA S3_SECRET_KEY=$k
    run check_secrets
    [ "$status" -eq 1 ]
    [[ "$output" == *"S3_SECRET_KEY can't contain"* ]]
    [[ "$output" != *"$k"* ]]
  done
  # What weed carries as written still works, as it did before: - _ . # @ and the rest
  for k in 'AK-IA' 'velero_user.1' 'MySecret@123' 'ab#c' 'a+b/c=' '!$%&*()'; do
    S3_ACCESS_KEY=$k S3_SECRET_KEY=$k
    check_secrets
  done
  S3_ACCESS_KEY="" S3_SECRET_KEY="" S3_REVOKE_ACCESS_KEYS='good1 b;d'
  run check_secrets
  [ "$status" -eq 1 ]
  [[ "$output" == *"S3_REVOKE_ACCESS_KEYS"* ]]
  S3_REVOKE_ACCESS_KEYS='good1 b-d'
  check_secrets
  S3_REVOKE_ACCESS_KEYS=""
  for u in admin Admin ops.admin _svc s15user 1admin 'svc$' 'a!b' user@example.com; do SWFS_USER=$u S3_USER=$u; check_secrets; done
  # S3_USER defaults to SWFS_USER, and goes to weed shell: a ' or ; there is refused, unless S3_USER is set apart
  for u in "o'brien" 'ad;min'; do
    SWFS_USER=$u S3_USER=$u
    run check_secrets
    [ "$status" -eq 1 ]
    [[ "$output" == *"S3_USER (unset, it is SWFS_USER) can't be empty"* ]]
    SWFS_USER=$u S3_USER=obrien
    check_secrets
  done
  for u in ad:min 'ad min' ' admin' 'ad"min' 'ad`min' 'ad\min' '{admin}' '#admin' $'ad\tmin' ''; do
    SWFS_USER=$u S3_USER=admin
    run check_secrets
    [ "$status" -eq 1 ]
    [[ "$output" == *"SWFS_USER can't be empty, contain a space"* ]]
  done
  SWFS_USER=admin S3_USER=admin
  check_secrets
  SWFS_USER='ad min'
  run check_secrets
  [ "$status" -eq 1 ]
  SWFS_USER=admin SWFS_PASSWORD="${VEC[long]}x"
  run check_secrets
  [ "$status" -eq 1 ]
  [[ "$output" == *"longer than 128"* ]]
  SWFS_PASSWORD=$'Aa1\tpass'
  run check_secrets
  [ "$status" -eq 1 ]
  for n in "${VEC_NAMES[@]}"; do SWFS_PASSWORD=${VEC[$n]}; check_secrets; done
  REGISTRY_MODE=1 REG_USER='ro:bot' REG_PASS=x SWFS_PASSWORD=changeme
  run check_secrets
  [ "$status" -eq 1 ]
}
@test "S26: a revoke list over several lines is read whole, as before" {
  S3_ACCESS_KEY=k3 S3_SECRET_KEY=abc S3_REVOKE_ACCESS_KEYS=$'k1\nk3' S3_USER=admin
  die() { echo "DIE: $*"; exit 1; }
  run resolve_s3_keys
  [ "$status" -eq 1 ]
  [[ "$output" == *"names the key this run configures"* ]]
}
@test "S26: S3_REVOKE_ACCESS_KEYS isn't globbed" {
  cd "$T"; touch kfile
  S3_ACCESS_KEY='k*' S3_SECRET_KEY=abc S3_REVOKE_ACCESS_KEYS='k*' S3_USER=admin
  die() { echo "DIE: $*"; exit 1; }
  run resolve_s3_keys
  [ "$status" -eq 1 ]
  [[ "$output" == *"names the key this run configures"* ]]
}
@test "S25: Loki's config and the credentials file carry each key exactly, and plain keys as before" {
  local a k
  ENABLE_MONITORING=true LOKI_BUCKET=loki-logs SWFS_S3_PORT=8333 LOKI_PORT=3100 PROMETHEUS_EXT_PORT=9090 CLUSTER_NAME=c
  mkdir -p /opt/monitoring/loki /opt/seaweedfs
  for a in aaaa1111bbbb2222 AKIA1234; do
    for k in cccc3333dddd4444eeee5555ffff6666 'wJal+r/X=U.t_n-F' '-x=' 'a.b'; do
      S3_ACCESS_KEY=$a S3_SECRET_KEY=$k
      generate_loki_config >/dev/null 2>&1
      [ "$(yaml_get /opt/monitoring/loki/loki-config.yaml storage_config aws access_key_id)" = "$a" ]
      [ "$(yaml_get /opt/monitoring/loki/loki-config.yaml storage_config aws secret_access_key)" = "$k" ]
      write_monitoring_credentials >/dev/null
      [ "$(bash -c 'source /opt/seaweedfs/monitoring-credentials.env; printf "%s\n%s" "$MONITORING_S3_ACCESS_KEY" "$MONITORING_S3_SECRET_KEY"')" = "$a"$'\n'"$k" ]
    done
  done
  S3_ACCESS_KEY=aaaa1111bbbb2222 S3_SECRET_KEY=cccc3333dddd4444eeee5555ffff6666
  generate_loki_config >/dev/null 2>&1; write_monitoring_credentials >/dev/null
  grep -qx '    secret_access_key: cccc3333dddd4444eeee5555ffff6666' /opt/monitoring/loki/loki-config.yaml
  grep -qx 'MONITORING_S3_SECRET_KEY=cccc3333dddd4444eeee5555ffff6666' /opt/seaweedfs/monitoring-credentials.env
}
