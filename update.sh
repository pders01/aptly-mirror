#!/usr/bin/env bash
# Refresh koha mirror, fold in custom packages, publish atomically.
# Cron-invoked. Idempotent — safe to re-run.
set -euo pipefail

cd "$(dirname "$0")"

MIRROR="koha"
LOCAL_REPO="custom"
DIST="stable"
COMPONENT="main"
GPG_KEY="${GPG_KEY:?set GPG_KEY to signing key fingerprint or uid}"
PASSPHRASE_FILE="${PASSPHRASE_FILE:-/root/.gnupg/passphrase}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

run() { docker compose run --rm aptly "$@"; }

# First-run bootstrap. Mirror/repo creation is idempotent-ish: aptly errors
# if they already exist, so probe first.
if ! run mirror show "$MIRROR" >/dev/null 2>&1; then
  run mirror create -architectures="amd64,arm64" \
    "$MIRROR" https://debian.koha-community.org/koha "$DIST" "$COMPONENT"
fi

if ! run repo show "$LOCAL_REPO" >/dev/null 2>&1; then
  run repo create -distribution="$DIST" -component="$COMPONENT" "$LOCAL_REPO"
fi

# Pull upstream, snapshot both sources, merge, publish.
run mirror update "$MIRROR"

SNAP_M="${MIRROR}-${STAMP}"
SNAP_R="${LOCAL_REPO}-${STAMP}"
SNAP_FINAL="combined-${STAMP}"

run snapshot create "$SNAP_M" from mirror "$MIRROR"
run snapshot create "$SNAP_R" from repo "$LOCAL_REPO"
run snapshot merge -latest "$SNAP_FINAL" "$SNAP_M" "$SNAP_R"

# First publish uses `publish snapshot`; subsequent updates use `publish switch`.
if run publish list -raw 2>/dev/null | grep -q "^\. $DIST$"; then
  run publish switch \
    -gpg-key="$GPG_KEY" \
    -passphrase-file="$PASSPHRASE_FILE" \
    "$DIST" "$SNAP_FINAL"
else
  run publish snapshot \
    -gpg-key="$GPG_KEY" \
    -passphrase-file="$PASSPHRASE_FILE" \
    -distribution="$DIST" \
    -component="$COMPONENT" \
    "$SNAP_FINAL"
fi

# Drop snapshots/packages no longer referenced by any publish.
run snapshot cleanup || true
run db cleanup || true
