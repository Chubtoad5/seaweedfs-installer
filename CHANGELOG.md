# Changelog — seaweedfs-installer

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
