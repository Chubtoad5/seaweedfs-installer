# Changelog — seaweedfs-installer

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
