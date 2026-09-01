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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DEBIAN_FRONTEND=noninteractive
# Some packages (e.g. fuse3) ship a conffile that already exists in the base
# image; keep the existing version non-interactively so dpkg never blocks on a
# conffile prompt (which fails with "end of file on stdin").
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log "installing system packages (docker, fuse-overlayfs, postgresql-client)"
sudo apt-get update -qq
# fuse-overlayfs lets the Docker daemon use an overlay storage driver inside the
# Cloud Agent VM's own container filesystem; acl lets start.sh grant the agent
# user scoped access to the Docker socket without making it world-writable.
sudo apt-get install "${APT_OPTS[@]}" --no-install-recommends \
  ca-certificates curl acl \
  docker.io fuse-overlayfs uidmap iptables \
  postgresql-client

arch="$(dpkg --print-architecture)"

# --- Deno -------------------------------------------------------------------
if command -v deno >/dev/null 2>&1 && deno --version 2>/dev/null | grep -q "deno ${DENO_VERSION#v}"; then
  log "deno ${DENO_VERSION} already present"
else
  log "installing deno ${DENO_VERSION} to /usr/local/bin"
  # DENO_INSTALL=/usr/local places the binary at /usr/local/bin/deno (on PATH
  # for every user without shell-profile mutation). The upstream installer
  # selects the correct build for the host architecture.
  curl -fsSL https://deno.land/install.sh | sudo DENO_INSTALL=/usr/local sh -s "${DENO_VERSION}" >/dev/null
fi
deno --version | head -1

# --- Supabase CLI -----------------------------------------------------------
if command -v supabase >/dev/null 2>&1 && [ "$(supabase --version 2>/dev/null | head -1)" = "${SUPABASE_CLI_VERSION}" ]; then
  log "supabase CLI ${SUPABASE_CLI_VERSION} already present"
else
  case "$arch" in
    amd64|arm64) sb_arch="$arch" ;;
    *) echo "INSTALL: ERROR: unsupported architecture '$arch' for Supabase CLI" >&2; exit 1 ;;
  esac
  log "installing supabase CLI ${SUPABASE_CLI_VERSION} (${sb_arch})"
  tmp_deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$tmp_deb" \
    "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_${SUPABASE_CLI_VERSION}_linux_${sb_arch}.deb"
  sudo dpkg -i "$tmp_deb"
  rm -f "$tmp_deb"
fi
supabase --version | head -1

# --- Docker configuration ---------------------------------------------------
log "configuring docker daemon (fuse-overlayfs storage driver)"
sudo mkdir -p /etc/docker
printf '{\n  "storage-driver": "fuse-overlayfs"\n}\n' | sudo tee /etc/docker/daemon.json >/dev/null

# If a daemon is already running with a different storage driver (e.g. the base
# image auto-started Docker before this config existed), stop it so start.sh can
# bring it back up with fuse-overlayfs. Kill by PID, never by name.
if sudo docker info >/dev/null 2>&1; then
  current_driver="$(sudo docker info --format '{{.Driver}}' 2>/dev/null || true)"
  if [ "$current_driver" != "fuse-overlayfs" ]; then
    log "restarting docker to apply fuse-overlayfs (was: ${current_driver:-unknown})"
    dpid="$(pgrep -x dockerd || true)"
    if [ -n "$dpid" ]; then
      sudo kill "$dpid" 2>/dev/null || true
    fi
    sleep 2
  fi
fi

# Allow the agent user to talk to the daemon without sudo on a normal login
# session. Group membership is durable; start.sh additionally applies a scoped
# ACL per boot for contexts where the group is not yet effective.
sudo groupadd -f docker
sudo usermod -aG docker "$(id -un)"

# --- Warm the Supabase image cache ------------------------------------------
# Pulling the pinned local-stack images now bakes them into the environment
# snapshot so the first `supabase start` on a fresh agent is fast. Best-effort:
# a cold cache only makes the first start slower. Never disturb a stack that is
# already running (keeps this installer safe to re-run).
log "warming Supabase local-stack image cache"
if bash "${script_dir}/start.sh" >/tmp/install-docker-boot.log 2>&1; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  if (cd "$repo_root" && supabase status >/dev/null 2>&1); then
    log "supabase stack already running; leaving it untouched"
  elif (cd "$repo_root" && supabase start >/tmp/install-warm-start.log 2>&1); then
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
