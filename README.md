# aptly-mirror

Mirror of the [Koha](https://debian.koha-community.org/koha) APT repo with
[aptly], folded together with custom `.deb` packages, served over HTTPS by
Caddy with auto Let's Encrypt.

[aptly]: https://www.aptly.info/

## Stack

- **aptly** (cron-driven, profile `cli`) — pulls upstream, snapshots, signs,
  publishes to `data/public/`.
- **Caddy** (always-on) — TLS termination, ACME, static serve of `data/public/`.

Image: `ghcr.io/pders01/aptly` (public, multi-arch amd64/arm64).

## Quick start

```bash
cp .env.example .env  # set APT_DOMAIN + ACME_EMAIL
mkdir -p data gnupg

# On your workstation: create sign-only subkey, copy gnupg/ to host.
./scripts/setup-signing-subkey.sh <master-fingerprint>
# follow prompts, then rsync gnupg/ to deploy host

# On deploy host:
sudo chown -R 1000:1000 data gnupg
docker compose pull
docker compose up -d caddy
GPG_KEY=<subkey-fp> ./update.sh
```

Cron:

```cron
17 3 * * *  cd /srv/aptly-mirror && GPG_KEY=<fp> ./update.sh >> update.log 2>&1
```

## Adding custom packages

```bash
cp foo.deb data/incoming/
docker compose run --rm aptly repo add custom /var/lib/aptly/incoming/foo.deb
GPG_KEY=<fp> ./update.sh
```

## Layout

```
Dockerfile                  # debian:bookworm-slim + aptly + non-root user
docker-compose.yml          # caddy (up) + aptly (cli profile)
Caddyfile                   # TLS, autoindex, cache rules
aptly.conf                  # archs amd64+arm64, gpg provider
update.sh                   # bootstrap → mirror → snapshot → publish → gc
scripts/setup-signing-subkey.sh  # GPG subkey workflow
SECURITY.md                 # threat model + deploy checklist
HANDOFF.md                  # operator notes (untracked)
```

Runtime, not in git: `data/`, `gnupg/`.

## Releases

Image is pinned by short SHA in `docker-compose.yml`. Roll forward with:

```bash
SHA=$(git rev-parse --short HEAD)
docker buildx use reprepo-builder
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg GIT_SHA="$SHA" \
  -t ghcr.io/pders01/aptly:latest \
  -t ghcr.io/pders01/aptly:"$SHA" --push .
sed -i '' "s|aptly:[a-f0-9]\{7\}|aptly:$SHA|" docker-compose.yml
```

## See also

- [`SECURITY.md`](./SECURITY.md) — threat model, hardening, rotation, cloud
  notes.
