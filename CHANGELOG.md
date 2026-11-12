# Changelog — seaweedfs-installer

## v1.4.0 — 2026-11-12 — Any admin password works everywhere it goes

Spec 21 (chubtoad-automation).

### Fixed
- **The admin password reaches weed exactly** (S19). `seaweed-mini`'s `command:` was a folded string that compose
  interpolated, then split the way a shell would. So a `$` or `\` gave the Admin UI a different password than the Filer,
  Master and SMB, an unmatched `"` stopped the install, an invalid `${…}` stopped it **and printed the whole command,
  password included**, and with `&`, `;` or `|` compose quietly dropped the rest of the line, `-webdav=false` and every
  tuning and cluster flag with it. Now `command:` is a list, one single-quoted item per argument, with `$` written `$$`.
- **Grafana gets the password exactly** (S20), and its user name: a `$` in `SWFS_USER` gave Grafana a shorter name. Its
  environment lines were plain YAML that compose also interpolated: `$` was rewritten, `Aa1 #x` became `Aa1`, a trailing space was dropped, and `: ` or a trailing `:` stopped the install at
  "Monitoring stack setup failed". It is now a single-quoted item with `$$`.
- **A changed `SWFS_PASSWORD` reaches Grafana** (S21). Grafana reads its environment's password only when it creates
  its database, so it kept the first one while the install printed the new one. `/opt/monitoring/.grafana-auth` (0600)
  now holds a fingerprint of the password Grafana has, and a run whose password differs resets it with Grafana's own
  CLI, the password on stdin.
- **Samba gets a password of `-n` or `-e`** (S22): `printf`, not `echo`.
- **Passwords over 72 bytes install** (S23). Caddy hashed with bcrypt, which takes no more than 72, and the install
  stopped with "Failed to hash SWFS_PASSWORD with the Caddy image … Is the image available?". Caddy now hashes with
  argon2id, with the password on stdin rather than in `ps`, and the Caddyfile says `basic_auth argon2id`.
- **S3 keys reach `weed shell` exactly, or are refused** (S24). A key with a space or a leading space configured nothing
  while the step said it had; `;` cut the line in two; `\` and matched quotes were stripped, so requests failed their
  signature check. Now a key with a space, `;`, a quote, a backslash or a control character is refused before anything
  changes, and every other key goes in quotes as written. The step fails on weed's own error line, or when a plain key
  is missing from the identities weed prints, not on `error` or `failed` anywhere in the output.
- **Loki's config and `monitoring-credentials.env` carry the keys exactly** (S25): YAML single quotes and shell single
  quotes, for a key that isn't only letters and digits. Those files are byte-identical for keys that are.
- **`S3_REVOKE_ACCESS_KEYS` isn't globbed** (S26), so a `*`, `?` or `[` can't revoke other keys. A list over several
  lines is still read whole.
- **`IMAGE_PULL_PUSH_REF` defaults to images-pull-push v1.2.0,** which takes the registry user and password by position,
  so a registry password such as `--help` or `push` is a password.

### Changed
- **Checked before anything changes, each message naming the variable but never its value:** `SWFS_PASSWORD` with a
  control character or over 128 characters; `SWFS_USER` with a space, `:`, a quote, a backquote, a backslash, a brace or
  a control character, or a leading `#`, which the Caddyfile and the logins can't carry (with SMB on, `useradd` still
  decides the rest, as before; a backquote or a brace, which
  hardly anyone uses, is refused too); an S3 key, a key to revoke, or `S3_USER` (which defaults to `SWFS_USER`) that
  weed's shell would change (above): a `'` or `;` in the S3 user configured no working key while the install reported
  one; a registry user with `:` or a space at either end. Each of these
  failed or came out changed before, apart from the backquote and the brace. Generated keys always fit.
- **On the first run of v1.4.0 over an earlier release with monitoring on,** Grafana's admin password is set to
  `SWFS_PASSWORD` once, because there's no fingerprint yet. A password changed in Grafana's own UI is replaced then.
- **An existing install keeps its bcrypt hash** while the password is the same, so the Caddyfile and Caddy are left as
  they are. `seaweed-mini` and Grafana keep the same compose config hash for every password that worked before, so they
  aren't recreated. An install whose password compose changed gets `seaweed-mini` recreated once, with the real one.
- S27 (weed stripping matching outer quotes from `mini.options`) didn't reproduce on the bench: a password of
  `'Aa1pass'` worked across three starts. Nothing changes for it.
- `swfs-manual.md` follows: a compose-quoted password variable, the list `command:`, argon2id, `printf` for Samba and
  `weed shell`.

### Tests
- `tests/unit/passwords.bats`: every spec 21 test password through weed's compose command, Grafana's environment line
  (read back with PyYAML, and `$$` undone), Samba's input, Caddy's stdin and the Caddyfile, Grafana's reset and its
  fingerprint; the key rules and their messages; `S3_REVOKE_ACCESS_KEYS` with glob characters; weed shell's failure
  match; Loki's and the env file's values read back.
- `tests/integration/10-lifecycle.sh`: the install uses spec 21's full test password, and logs in with it at the Admin
  UI, the Filer, Grafana, SMB and S3; compose's own reading of both compose files is checked; a changed password reaches
  Grafana.
- `tests/scenarios/a5-upgrade.sh`: over the last release, `seaweed-mini` and Grafana aren't recreated, the Caddyfile is
  unchanged, and Grafana still takes the password.
- `tests/unit/entrypoint.bats`, `day2.bats`, `helper-pins.bats`: the list command, Caddy's stdin, and the v1.2.0 pin.
- `tests/password-vectors.txt`, `tests/vectors.bash`, `tests/secret-lint.py`, `tests/unit/secret-lint.bats`: spec 21's
  shared test passwords and static check.

## v1.3.1 — 2026-11-12 — The admin password reaches weed whole; /opt/seaweedfs is private

Spec 20 (chubtoad-automation), asked for by dap-blueprints Plan 01's Q46, from object-tech-ops 1.2.1.0's P3.

### Fixed
- **An admin password with a space, `*`, `?` or `[` now reaches the Admin UI whole** (S17). The `chrislusf/seaweedfs`
  image's `/entrypoint.sh` passes its arguments to weed unquoted (`exec /usr/bin/weed ... mini $ARGS $@`). So
  `-admin.password "P@ss w0rd"` reached weed as `P@ss` and `w0rd`: the Admin UI took only `P@ss`, and weed stopped
  reading flags at `w0rd`, ignoring `-webdav=false` and every tuning and cluster flag after it. `*`, `?` and `[` were
  globbed. Caddy, the Filer, SMB and Grafana, which get the password separately, were fine.
  - `seaweed-mini` now starts through `/opt/seaweedfs/weed-entrypoint.sh`, mounted read-only and run by the image's
    `/bin/sh`. It does what the image's script does for `mini` and passes the arguments whole:
    - FIPS 140-3 mode on;
    - `/data` given to the image's `seaweed` user when it isn't theirs;
    - weed run as that user.
  - An image without `su-exec` runs weed as root, as its own entrypoint did.
  - `seaweed-mq`, `seaweed-mount` and a volume node's `seaweed-volume` keep the image's entrypoint: nothing in their
    commands is quoted.
- **`/opt/seaweedfs` is root-only** (S18). weed saves its flags, the admin password among them, to
  `/opt/seaweedfs/mini/mini.options` with mode 644 at every start, and most of its data files are 644. `install`
  and `join` now make `/opt/seaweedfs` mode 700 on every run, so other users can't read them. The containers reach
  their data through bind mounts and aren't affected.

### Upgrading
- The first re-run recreates `seaweed-mini` once (its compose definition changed): a short pause for the Admin UI,
  Filer and S3. Caddy, `seaweed-mount`, Samba and NFS keep running.
- An install whose password had a space gets the whole password in the Admin UI, and the flags it lost come back. A
  command-line flag wins over the value weed saved in `mini.options`.

### Not changed
- The password is still on weed's command line, which any local user can see with `ps`.

## v1.3.0 — 2026-11-11 — Samba and NFS stay up on a re-run; the release in .install-state

Spec 18 (chubtoad-automation), asked for by object-tech-ops' Phase B, which re-runs the installer on every update.

### Fixed
- **A same-settings re-run no longer restarts Samba or the NFS server** (S15). Every run restarted both, so each
  re-run dropped every SMB session (`NT_STATUS_CONNECTION_DISCONNECTED`) and paused NFS clients. Now: nothing changed
  and the service running, it's left alone; a changed `smb.conf` reloads Samba (a failed reload restarts it), and a
  changed `/etc/exports` is re-exported with `exportfs -ra`, with no restart; a service that isn't running is started.
  Both still restart when the run replaced the `/mnt/seaweed` mount, which they'd otherwise keep serving: the
  `seaweed-mount` container is read right before and right after `docker compose up`, and the restart waits up to 60 s
  for the new FUSE mount. The log says which case applied.

### Added
- **`.install-state` records `SCRIPT_VERSION`** (S16), the release that last finished an `install` or `join` on the
  host. It's written last, so a failed run leaves the previous release's.

### Tests
- `tests/unit/services.bats`: each Samba and NFS case, the mount check, and where `SCRIPT_VERSION` is written.
- `tests/integration/20-day2.sh`: an SMB session held open across an identical re-run still works, and neither
  service restarts; a changed share and export reload and re-export in place; a stopped NFS server is started; a re-run
  that recreates `seaweed-mount` restarts both, and a new SMB session sees the new mount; `SCRIPT_VERSION` is recorded. A5 checks the upgrade records it.

## v1.2.2 — 2026-11-10 — Cluster mode installs again

### Fixed
- **`CLUSTER_MODE=cluster ./install-seaweedfs install` finishes** (spec 17, F1). It stopped at "Configuring S3
  credentials" in every release since v1.0.0. Cluster mode makes the control plane advertise the host's address, so the
  installer's `weed shell`, run inside the container, looked the Filer up at that address and dialled its gRPC port,
  18888, which cluster mode doesn't publish. Every `weed shell` the installer runs now names the container's own Filer,
  `-filer=localhost:8888`, and so do the cluster commands `join` prints. No new port is opened. Single-node installs
  never had the problem: there the Filer advertises the container's own address.
- **The replication commands `join` prints use the container's master port, 9333.** They used `SWFS_MASTER_PORT`,
  which is Caddy's port on the host, so they were wrong whenever that was changed.

### Documentation
- **A clustering section in the README:** the steps (install node 1 with `CLUSTER_MODE=cluster`, `join`, then two
  copies for new and existing data), and what this layout protects and doesn't. Losing a volume node keeps the data
  served; losing node 1 stops the cluster until it returns. The cluster's ports are unauthenticated, as SeaweedFS ships
  them. And `-filer=localhost:8888` for `fs.*` and `s3.*` commands run by hand.
- `CLUSTER_MODE`, `CLUSTER_REPLICATION` and the cluster ports are in the Configuration Variables table.

### Tests
- `tests/unit/cluster-shell.bats`: every `weed shell` names the local Filer.
- Spec 09 Phase 5's scenarios are part of this release:
  - **A4:** a cluster-mode install and a write on one node; a second node joins and the README's replication steps run.
    Node 2's own copies match byte for byte, and with node 2 stopped everything reads back through node 1. Node 2 rejoins
    and uninstalls.
  - **A5:** the last release installed and given data, then this version installed over it, with the data, keys,
    password and Caddy's root CA kept.

## v1.2.1 — 2026-11-09 — Air-gapped Docker on Rocky 10 and Leap 16

### Fixed
- **An air-gapped install on Rocky 10 or Leap 16 installs Docker from the bundle** (spec 15, F1 and F7, through the
  helpers). `IMAGE_PULL_PUSH_REF` now defaults to `images-pull-push` v1.1.2, whose bundle carries the running kernel's
  `kernel-modules-extra` on EL. `INSTALL_PACKAGES_REF` defaults to `install-packages` v1.1.3, whose SUSE bundle carries
  Docker's `container-selinux`. SeaweedFS exports its `INSTALL_PACKAGES_REF` to `image_pull_push.sh`, so both pins had to move.
  Before, the load of the image archive stopped at Docker's install on both.
- The bundle's licence notice points at the `LICENSES/` inside the images-pull-push archive, which lists Docker's packages
  and covers them with a written offer.

### Tests
- `tests/unit/helper-pins.bats` follows both pins. Phase 4's A1 (spec 09) is part of this release.

## v1.2.0 — 2026-11-08 — The helpers come from releases

### Changed
- **`image_pull_push.sh` and `install_packages.sh` are fetched from releases, `images-pull-push` `v1.1.1` and
  `install-packages` `v1.1.2`, instead of `main`.** So a merge in either no longer reaches this installer, or `ap-tools`,
  until a pin moves (spec 12).
- **A copy already in `utilities/` is reused only if it came from the same ref,** recorded beside it in a `.ref` file.
  Before, any copy was kept for good, so a host never saw a fix. A copy with no record is fetched again once.
- **Air-gapped, the bundle's copies are used, and nothing is downloaded.** With no copy there, the run stops and says to
  extract the whole bundle, or to set `SWFS_FORCE_ONLINE=true`. A `save` always fetches the pinned copies, even in a
  folder whose left-over sentinel makes it air-gapped, since it pulls images and packages anyway. So a second
  `ap-tools offline-prep` bundles the pinned helpers too.
- **`INSTALL_PACKAGES_REF` is passed on to `image_pull_push.sh`,** which reads it, so one setting covers both helpers.

### Added
- **`IMAGE_PULL_PUSH_REF`** (default `v1.1.1`) and **`INSTALL_PACKAGES_REF`** (default `v1.1.2`): the tag, branch or commit
  to fetch.
- **`IMAGE_PULL_PUSH_URL`** and **`INSTALL_PACKAGES_URL`**: full URLs, for a mirror. Each wins over its ref.
- **`IMAGE_PULL_PUSH_SHA256`** and **`INSTALL_PACKAGES_SHA256`**: optional checksums. A mismatch, or a failed download,
  stops the run and leaves no file.

### Tests
- `tests/unit/helper-pins.bats`: both default tags, the ref and URL settings, the export to `image_pull_push.sh`, reuse
  and refetch, both checksum cases, a failed download, and both air-gapped cases.

## v1.1.0 — 2026-11-06 — Day-2 fixes

The first release with `SCRIPT_VERSION`. Every fix was reproduced on Ubuntu 24.04 first, and each has a test that
failed before it. Settings, commands and exit codes that callers use are unchanged, apart from the two additions and
the S3 key change below.

### Fixed
- **A re-run with the same settings restarted Caddy,** dropping S3 and admin connections, because the password was
  hashed with a fresh salt on every run. The hash is kept in `/opt/caddy/.auth-hash` (mode 600) while the password is
  the same.
- **Exit 0 didn't mean Caddy was serving.** A value Caddy couldn't parse left it in a restart loop while the install
  exited 0. The Caddyfile is now validated before it replaces the running one, so a bad value stops the run and the
  running Caddy keeps its config. A failed container restart is an error, and the install waits up to 60 s for the
  Admin UI to answer through Caddy before it reports success.
- **A blank `MGMT_IP` was accepted,** for example when the network wasn't up yet, giving a Caddyfile with empty site
  addresses. `install` and `join` now refuse anything that isn't an IPv4 address. `save` and `uninstall` don't need it.
- **Passwords were readable by every user** in the compose files, and the install log kept every earlier password
  and S3 key. The compose files and the Caddyfile are now mode 600, the log keeps only the latest run's credentials,
  and the raw S3 identity output (which lists keys) is logged only on failure, masked. The latest block keeps its
  `API Key:` and `API Secret:` lines unchanged.
- **Non-default Prometheus or Grafana ports broke monitoring:** the scrape targets and Grafana's datasource used the
  published port inside the Docker network. They now use the containers' own ports.
- **`MONITORING_S3_ENDPOINT` was `http://…:8333`,** plain HTTP to a TLS port, and ignored `SWFS_S3_PORT`. It is now
  `https://<MGMT_IP>:<SWFS_S3_PORT>`, and the new `MONITORING_S3_CA` names Caddy's root CA.
- **The Filer's redirect to the Admin UI dropped a non-443 `SWFS_ADMIN_PORT`.** `ap-tools` installs use 9443, so
  their Caddyfile changes once.
- **A bare `push` exited 0 having pushed nothing.** It now pushes the images. It installs nothing of SeaweedFS's
  and records no install state, though `image_pull_push.sh` still installs Docker if it's missing, trusts the
  registry's certificate, and may restart Docker.
- **Changing `SWFS_USER` made uninstall delete the wrong account:** the new name inherited the old one's "created by
  the installer" flag. The previous user now leaves Samba, and its account is deleted only if the installer created
  it.
- **UFW: uninstall deleted rules that were there before the install,** because `ufw allow` succeeds for an existing
  rule and the installer claimed it. It now claims only the rules it adds, as it already did with firewalld.

### Added
- **`S3_REVOKE_ACCESS_KEYS`:** access keys to delete from `S3_USER` after this run's key is configured. A new key is
  added rather than replacing the old one, so this is how an old key stops working. The run refuses to revoke the key
  it is configuring.
- A warning when `DEFAULT_FILER_DIR_NAME` differs from the last install's, because the shares move to an empty folder.
- The README says that re-running with the same image tag, such as `latest`, doesn't pull a newer image.

### Changed
- **S3 keys on a re-run:** with neither `S3_ACCESS_KEY` nor `S3_SECRET_KEY` passed, a re-run now keeps the pair the
  last install recorded for the same `S3_USER`, instead of adding a new random pair each time. A passed key still
  wins, and a first install still generates one. The pair is recorded in `.install-state`. For an install from
  before 1.1.0, the newest pair in the install log of the folder you run from is kept, if this host's running
  SeaweedFS has that key, so a log copied from another host is never used. Otherwise it adds a new pair, and the
  old one keeps working.
- **The install log keeps only the current credentials.** Older S3 keys that were never revoked keep working, and
  are listed in the Filer at `/etc/iam/identities/<user>.json`.

### Upgrading
- The first re-run after upgrading restarts Caddy once, because no stored hash exists yet. It also tightens the file
  modes and clears old credentials from the log.

## 2026-10-23 — Manual install guide brought in line with the script (docs/manual-sync)

### Changed (docs only)
- **`swfs-manual.md`:**
  - images pinned to the script defaults (`seaweedfs:4.30`, `caddy:2.11.3`) instead of `:latest`
  - new "What this guide does not set up" table: the landing page, install state / converge /
    uninstall, firewall and SELinux handling. A manual install opens the Admin UI and its sign-in
    directly at `/`, which is fine because nothing depends on the landing page
  - the admin site gets `/ca.crt` and the `Secure` session cookie
  - Caddy `/data` and `/config` are persisted, so the CA survives recreates (the monitoring step's
    `--force-recreate caddy` used to replace it)
  - the unused `AWS_*` environment on `seaweed-mini` is dropped (it exposed the admin password); MQ
    gets `depends_on`
  - `fuse.conf` is appended to, not overwritten
  - the SMB user is created safely when a group of the same name exists
  - `testparm` and a :445 check before and after the Samba restart; the SELinux
    `samba_share_fusefs` note added; Windows `net use` prompts for the password (`*`)
  - the NFS export gets the required `fsid=1` and a note on limiting clients; new optional
    NFS refresh-timer step
  - CA download via `/ca.crt` or the host path
- **README:** a "Manual installation" pointer (what the guide covers and leaves out), and the
  `DEBUG` description matches the new package-output logging.

## 2026-10-23 — Samba setup is verified; package failures show their reason (fix/samba-verify-package-output)

### Fixed
- **Samba could end up broken without the install saying so.** After writing the share,
  `install` now runs `testparm -s` before restarting Samba (stopping with a clear error if the
  config is rejected or the share was not loaded, and leaving the running `smbd` untouched), then
  waits up to 10 s for the service to be active and listening on 445, and fails if it is not.
- **Samba/NFS package failures were reported without a reason when `DEBUG=0`.** The
  `install_packages.sh` output is now appended to `seaweedfs-install.log` (and shown with
  `DEBUG=1`); on failure the last 15 lines are printed before the run stops.

## 2026-10-23 — Caddy CA persists; NFS_CLIENTS; upgrades of older installs (feature/persist-caddy-data-nfs-clients)

### Fixed
- **The Caddy CA changed whenever the container was recreated** (image bump, compose change,
  re-install), so every client that trusted it broke. Caddy's `/data` and `/config` are now
  bind-mounted from `/opt/caddy/data` and `/opt/caddy/config`. On the first run over an older
  install the existing CA and certificates are copied out of the running container before it is
  recreated, so the CA is kept.
- **Upgrading an install from before the install-state file failed the port preflight** on its own
  containers. Ports published by this installer's `seaweed-*` containers are no longer counted as
  conflicts.

### Added
- **`NFS_CLIENTS`** (default `*`): client list for the NFS export (hosts, IPs, CIDRs, wildcards,
  `@netgroups`; space- or comma-separated), validated before any change is made.
- README **"Upgrading an existing install"**: the settings to carry over on every re-run.

### Upgrade notes
- The compose file changes (two new Caddy volumes), so the first re-run **recreates
  `seaweed-caddy`** (a few seconds of downtime on the web endpoints). The CA is migrated first and
  the log prints its fingerprint. SeaweedFS containers and data are untouched.
- Re-runs rewrite the NFS export line from `NFS_CLIENTS` — pass a restricted scope every time.

## 2026-10-23 — Landing page behind the Admin UI login; Admin UI catch-all route (feature/admin-splash-login)

### Fixed
- **Admin UI pages added by newer SeaweedFS releases returned 404.** The admin site proxied an
  explicit list of Admin UI paths; SeaweedFS 4.30 added **Plugin** (`/plugin/lanes/…`), which fell
  through to the landing page's file server. The admin site now proxies every path except the
  landing page, `/ca.crt` and the `/<DEFAULT_FILER_DIR_NAME>` redirect to the Admin UI.

### Added
- **`SPLASH_REQUIRE_LOGIN`** (default `true`): the landing page is served only to a browser with a
  valid Admin UI session (Caddy `forward_auth` on `/admin`); signed-out browsers get the Admin UI's
  own sign-in page, and a successful sign-in lands on the landing page instead of the dashboard.
  `false` keeps the previous public landing page. Re-runs converge in both directions.
- **`/ca.crt`** downloads Caddy's local root CA (only that one file is reachable).
- The Admin UI session cookie (`admin-session`) gets the `Secure` flag.
- **Landing page refresh:** host, SeaweedFS/Caddy versions and mode; per-service FQDNs baked in at
  install (no more rewriting the `admin` label of the browser's hostname); MQ broker; S3 user and
  install-time buckets with an `aws` example; Linux/macOS SMB and an NFS `/etc/fstab` line plus the
  `NFS_META_REFRESH_SEC` visibility note; the CA download and `curl --cacert` Filer API examples
  instead of `curl -k`; and, when signed in, a live status panel (stored chunks, size, volumes, disk use,
  S3 buckets) from the Admin UI JSON API, which hides itself if those internal endpoints change.

### Upgrade notes
- Re-running `install` regenerates the Caddyfile and landing page and restarts (does not recreate)
  `seaweed-caddy`; data, credentials and the Caddy CA are untouched.
- Anything that fetched the landing page anonymously and expected `200` now gets `307 /login`
  (set `SPLASH_REQUIRE_LOGIN=false` to keep it public). The Filer, Master and S3 endpoints are
  unchanged.

## 2026-09-09 — Idempotence release (feature/idempotence-phase2)

Idempotence, distro-correctness and uninstall-fidelity pass. Re-running `install` now
reconciles the host instead of duplicating configuration, `uninstall` is driven by what the
installer actually did rather than by the environment it happens to be run with, and the
script fails fast — before changing anything — on the conditions that used to produce a
half-installed host.

### Fixed
- **Truthful exit codes.** The script exits `0` only when the requested operation actually
  succeeded. Critical-path failures — `docker compose up`, the Filer not becoming ready
  within 120 s, S3 credential/bucket configuration, package installation, image
  pull/push/load, save-archive creation, registry login — abort with a non-zero exit and an
  `ERROR:` message. Callers such as `ap-tools` can rely on the exit code. Non-critical issues
  (Loki slow to report ready, artifact upload failures) remain `WARNING` and do not fail the
  install.
- **Re-running `install` reconciles instead of duplicating.** Samba/NFS config blocks are
  marker-tagged and replaced rather than appended twice; changed bind-mounted configs
  (Caddyfile, monitoring configs) restart only the affected container; and features toggled
  **off** since the previous install (`ENABLE_MQ`, `ENABLE_MONITORING`, `ENABLE_SMB`,
  `ENABLE_NFS`) are torn down (`--remove-orphans` plus recorded-state cleanup).
- **`uninstall` is state-driven and non-destructive to the host.** The seaweedfs share block
  is removed from `/etc/samba/smb.conf` by its markers — the host's `smb.conf` is never
  deleted or wholesale-replaced, so a second `uninstall` is a safe no-op. The system user is
  removed **only if this installer created it**. `/etc/fuse.conf` is restored according to
  what install actually did. Firewall rules and a changed `samba_share_fusefs` SELinux boolean
  are reverted to exactly the recorded state. Installs predating the state file fall back to
  evidence-based cleanup and never remove user accounts.
- **Distro correctness** — per-distro NFS package selection, firewalld/UFW handling, and
  SELinux handling.
- **Security** — the landing page no longer shows a password, secrets are kept out of stdout,
  and file permissions are tightened (credential files mode 600; the credential-bearing
  install log is removed at uninstall and the uninstall log written 600).
- **A stale air-gap sentinel is caught.** If `swfs-save-version.txt` is present but the image
  archives are missing, install aborts with instructions instead of failing obscurely; set
  `SWFS_FORCE_ONLINE=true` to ignore it.
- **CLI hardening** — unknown arguments are rejected with a usage error (exit 1), `push`
  without `-registry` is rejected, and `help` exits 0.
- **Artifacts-dir creation tolerates HTTP 409** (already exists) instead of failing the install.
- Bounded the legacy `smb.conf` block removal (no unterminated `sed` range), exempted
  `uninstall` from the `curl`/`openssl` preflight, and suppressed redirection-failure noise
  from `die()` when the log is unwritable.

### Added
- **Fail-fast preflight** — port-in-use and `nfsd`-availability checks run **before any
  changes** are made, so a host with something already on the port (or a kernel without nfsd)
  fails honestly instead of part-installing.
- **`/opt/seaweedfs/.install-state`** (mode 600) recording node role, which features this
  installer configured, resolved service/share/user names, whether the user account was
  created by the installer, how `/etc/fuse.conf` was handled, exactly which firewall entries
  were added, the prior SELinux boolean value, and the registry session and loaded images.
  Uninstall and re-install reconciliation both read it.
- **Firewall and SELinux handling** — firewalld (Rocky/RHEL, Leap 16) and UFW (Ubuntu) ports
  for enabled features are opened and recorded; only entries the installer actually added are
  claimed. With SELinux enforcing and SMB enabled, `samba_share_fusefs` is set (prior value
  recorded); a loud warning with exact remediation is printed if the boolean is unavailable.
- **`SWFS_FORCE_ONLINE`** and **`SWFS_REMOVE_IMAGES`** environment variables.
- README sections: Behavior Notes, exit codes, install-state file, firewall/SELinux handling,
  security notes.
- `install-seaweedfs` is now tracked executable (mode 755).

### Unchanged
- CLI surface (`install`, `join -master`, `save`, `push`, `uninstall`, `help`), the
  `CLUSTER_MODE` clustering contract, all `ENABLE_*` toggles, and every variable forwarded by
  `ap-tools` are unchanged.

### Known limitation
- UFW cannot model the NFSv3 dynamic `mountd` port — pin `mountd` or use firewalld if remote
  NFSv3 clients are blocked.
