# SECURITY

Threat model + hardening notes for cloud deployment of `aptly-mirror`.

## Threat model

APT clients verify packages via signed `Release`. Transport integrity is *not*
required for correctness — but is required for confidentiality and DoS
resistance. The high-value asset is **the GPG signing key**: anyone with it can
sign malicious `.deb`s that every client trusts.

Ranked risks:

1. **Signing key compromise** → silent persistence on every consumer host.
2. **Custom-repo write access** → arbitrary `.deb` injection (signed by us).
3. **Image / supply-chain compromise** → backdoored `aptly` or base image.
4. **Host compromise** → mirror tampering, key theft, lateral movement.
5. **Transport MITM** → traffic analysis (which packages, which versions);
   integrity is already covered by APT signature verification.

## What is hardened in this repo

| Area | Mitigation | File |
|------|------------|------|
| TLS termination + ACME | Caddy with auto Let's Encrypt | `Caddyfile`, `docker-compose.yml` |
| Container privileges | `cap_drop: [ALL]`, `no-new-privileges`, non-root UID 1000 | `Dockerfile`, `docker-compose.yml` |
| Filesystem | Caddy `read_only: true` + `tmpfs:/tmp` | `docker-compose.yml` |
| Resource caps | `mem_limit`, `pids_limit` on both services | `docker-compose.yml` |
| Static-asset cache rules | `.deb` immutable, `Release` no-cache | `Caddyfile` |
| HSTS + nosniff + Server hide | Security headers on autoindex | `Caddyfile` |
| Aptly upstream key pinning | `signed-by=/etc/apt/keyrings/aptly.gpg` | `Dockerfile` |
| Sign-only subkey workflow | Master stays offline, 1y subkey on host | `scripts/setup-signing-subkey.sh` |

## What still needs operator action

These are **not** automated. Do them manually before exposing the mirror.

### Required

- Set `APT_DOMAIN` and `ACME_EMAIL` in environment / `.env` before
  `docker compose up`. Without these Caddy refuses to start.
- Run `scripts/setup-signing-subkey.sh <master-fp>` on your workstation. Copy
  resulting `gnupg/` to deploy host with `rsync -a --chmod=700`. Move the
  generated `*.rev` revocation cert offline.
- On deploy host: `chown -R 1000:1000 ./data ./gnupg` so non-root container
  user can read/write.
- Firewall: only `:80`, `:443` public. SSH key-only, no password auth.
- Pin the upstream Koha signing key in `update.sh` once verified — currently
  TOFU on first `aptly mirror create`.

### Recommended

- **Pin base image by digest.** Replace `FROM debian:bookworm-slim` with
  `FROM debian@sha256:...`. Update via Renovate / Dependabot.
- **Image scanning in CI.** `trivy image ghcr.io/pders01/aptly:<tag>` — fail
  build on critical CVEs.
- **Cosign-sign images.** `cosign sign ghcr.io/pders01/aptly:<sha>`. Verify
  on pull.
- **Restrict `data/incoming/` write access.** Anyone who can drop a file
  there controls every client. Consider a CI-only upload path with build
  attestation, not interactive `cp`.
- **Encrypted volume.** `data/` on EBS-encrypted / GCP-PD / LUKS. Don't store
  on raw `/var/lib/docker/volumes/`.
- **Backup `data/db/` + `data/pool/`** to a *different* blast radius than
  `gnupg/`. Never colocate signing material with public artifacts.
- **Stale-mirror alert.** Page if last successful publish > 48h — clients
  miss security patches silently otherwise.
- **Rootless docker / podman** if you don't trust the `docker` group as
  root-equivalent (it is).
- **HSM / KMS-backed signing** for higher assurance: `gpg-agent` socket bound
  to a YubiKey, or AWS/GCP KMS asymmetric sign. Subkey priv never on disk.

## Subkey rotation

Annual default. To rotate before expiry or after suspected exposure:

```bash
./scripts/setup-signing-subkey.sh --rotate <master-fp>
# copy new gnupg/ to host
# update GPG_KEY env var in cron / systemd unit to new fingerprint
```

If subkey is **known compromised**:

1. Import the saved `*.rev` revocation cert: `gpg --import <fp>.rev`.
2. Push revocation: `gpg --send-keys <master-fp>` (or to your keyserver).
3. Generate a new subkey via `--rotate`.
4. Notify downstream consumers — they pin trust to the master, the revoked
   subkey ID will be refused after they refresh.

## Compose → real cloud

Single-host VM is fine for `docker compose up -d`. Beyond that:

- **ECS Fargate / Cloud Run jobs** for the cron-driven `aptly` task; pass
  `gnupg/` via Secrets Manager / Secret Manager (not bind-mount).
- **EFS / Filestore** for `data/` shared between Caddy (RO) and aptly job
  (RW). Add file-lock around publish if multiple update tasks could race.
- **WAF / CDN in front** is optional — APT clients don't benefit much, and a
  CDN must respect `Cache-Control: no-cache` on `Release` files or clients
  see a stale tree.

## Files removed during hardening

- `nginx.conf` — replaced by `Caddyfile`. Caddy provides static serve,
  autoindex, and ACME in one process.
