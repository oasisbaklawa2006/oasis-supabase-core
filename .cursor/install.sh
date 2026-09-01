#!/usr/bin/env bash
# Cloud Agent install phase for the Oasis Supabase Core backend.
#
# Installs the durable toolchain the repository's canonical checks require:
#   - Deno (edge-function `deno test` / `deno lint`)
#   - Supabase CLI (pinned to the version used by migration CI)
#   - PostgreSQL client `psql` (semantic-manifest SQL execution)
#   - Docker engine + fuse-overlayfs (runs the local Supabase stack)
#
# It is idempotent: every step is safe to re-run and converges on the same
# state. Per-boot daemon startup and kernel tuning live in start.sh, not here.
set -euo pipefail

# Keep these aligned with .github/workflows/migration-ci.yml (SUPABASE_CLI_VERSION)
# and .github/workflows/edge-function-governance.yml (denoland/setup-deno v2.x).
SUPABASE_CLI_VERSION="2.110.0"
DENO_VERSION="v2.9.6"

log() { echo "INSTALL: $*"; }

export DEBIAN_FRONTEND=noninteractive
# Some packages (e.g. fuse3) ship a conffile that already exists in the base
# image; keep the existing version non-interactively so dpkg never blocks on a
# conffile prompt (which fails with "end of file on stdin").
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log "installing system packages (docker, fuse-overlayfs, postgresql-client)"
sudo apt-get update -qq
# fuse-overlayfs lets the Docker daemon use an overlay storage driver inside the
# Cloud Agent VM's own container filesystem.
sudo apt-get install "${APT_OPTS[@]}" --no-install-recommends \
  ca-certificates curl \
  docker.io fuse-overlayfs uidmap iptables \
  postgresql-client

# --- Deno -------------------------------------------------------------------
if command -v deno >/dev/null 2>&1 && deno --version 2>/dev/null | grep -q "deno ${DENO_VERSION#v}"; then
  log "deno ${DENO_VERSION} already present"
else
  log "installing deno ${DENO_VERSION} to /usr/local/bin"
  # DENO_INSTALL=/usr/local places the binary at /usr/local/bin/deno (on PATH
  # for every user without shell-profile mutation).
  curl -fsSL https://deno.land/install.sh | sudo DENO_INSTALL=/usr/local sh -s "${DENO_VERSION}" >/dev/null
fi
deno --version | head -1

# --- Supabase CLI -----------------------------------------------------------
if command -v supabase >/dev/null 2>&1 && [ "$(supabase --version 2>/dev/null | head -1)" = "${SUPABASE_CLI_VERSION}" ]; then
  log "supabase CLI ${SUPABASE_CLI_VERSION} already present"
else
  log "installing supabase CLI ${SUPABASE_CLI_VERSION}"
  tmp_deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$tmp_deb" \
    "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_${SUPABASE_CLI_VERSION}_linux_amd64.deb"
  sudo dpkg -i "$tmp_deb"
  rm -f "$tmp_deb"
fi
supabase --version | head -1

# --- Docker configuration ---------------------------------------------------
log "configuring docker daemon (fuse-overlayfs storage driver)"
sudo mkdir -p /etc/docker
printf '{\n  "storage-driver": "fuse-overlayfs"\n}\n' | sudo tee /etc/docker/daemon.json >/dev/null

# Allow the agent user to talk to the daemon without sudo. Group membership is
# durable; the socket permission is (re)applied per boot in start.sh.
sudo groupadd -f docker
sudo usermod -aG docker "$(id -un)"

# --- Warm the Supabase image cache ------------------------------------------
# Pulling the ~2GB of pinned local-stack images now bakes them into the
# environment snapshot so the first `supabase start` on a fresh agent is fast.
# This is best-effort: a cold cache only makes the first start slower.
log "warming Supabase local-stack image cache"
if sudo "$(command -v bash)" "$(dirname "$0")/start.sh" >/tmp/install-docker-boot.log 2>&1; then
  if (cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" && supabase start >/tmp/install-warm-start.log 2>&1); then
    supabase stop --no-backup >/dev/null 2>&1 || true
    log "image cache warmed"
  else
    log "WARN: warmup 'supabase start' did not complete; images will pull on first use"
    supabase stop --no-backup >/dev/null 2>&1 || true
  fi
else
  log "WARN: could not start docker during install; images will pull on first use"
fi

log "install complete"
