#!/usr/bin/env bash
# Cloud Agent start phase for the Oasis Supabase Core backend.
#
# Runs on every boot. It performs the per-pod initialization the local Supabase
# stack needs and then returns (it does not stay in the foreground):
#   1. Disable bridge netfilter so same-bridge container<->container traffic is
#      L2-switched instead of being forced through iptables and dropped. Without
#      this the Supabase `realtime` service cannot reach `db` and `supabase start`
#      fails during schema initialization.
#   2. Start the Docker daemon (idempotently) with the fuse-overlayfs driver.
#   3. Make the Docker socket usable by the agent user.
set -euo pipefail

log() { echo "START: $*"; }

# --- 1. Bridge networking fix ----------------------------------------------
sudo modprobe br_netfilter 2>/dev/null || true
if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
  if ! sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 \
    || ! sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 \
    || [ "$(sudo sysctl -n net.bridge.bridge-nf-call-iptables)" != "0" ] \
    || [ "$(sudo sysctl -n net.bridge.bridge-nf-call-ip6tables)" != "0" ]; then
    echo "START: ERROR: failed to disable bridge netfilter" >&2
    exit 1
  fi
fi
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# --- 2. Docker daemon -------------------------------------------------------
if sudo docker info >/dev/null 2>&1; then
  if ! sudo docker info --format '{{.Driver}}' 2>/dev/null | grep -qx 'fuse-overlayfs'; then
    log "restarting docker daemon to apply fuse-overlayfs storage driver"
    sudo pkill -x dockerd 2>/dev/null || true
    sleep 1
  else
    log "docker daemon already running"
  fi
fi

if ! sudo docker info >/dev/null 2>&1; then
  log "starting docker daemon"
  sudo mkdir -p /var/log
  sudo bash -c 'nohup dockerd >/var/log/dockerd.log 2>&1 &'
  for _ in $(seq 1 30); do
    if sudo docker info >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if ! sudo docker info >/dev/null 2>&1; then
    echo "START: ERROR: docker daemon did not become ready" >&2
    tail -n 40 /var/log/dockerd.log >&2 2>/dev/null || true
    exit 1
  fi
  log "docker daemon ready"
fi

if ! sudo docker info --format '{{.Driver}}' 2>/dev/null | grep -qx 'fuse-overlayfs'; then
  echo "START: ERROR: docker storage driver is not fuse-overlayfs" >&2
  exit 1
fi

# --- 3. Docker socket access ------------------------------------------------
# Single-user Cloud Agent VM: widen socket access so the agent user can run
# docker/supabase without sudo before group membership is refreshed.
if [ -S /var/run/docker.sock ]; then
  if ! sudo chmod 666 /var/run/docker.sock 2>/dev/null; then
    echo "START: ERROR: failed to make Docker socket accessible" >&2
    exit 1
  fi
fi

if ! docker info >/dev/null 2>&1; then
  echo "START: ERROR: agent user cannot access Docker socket" >&2
  exit 1
fi

log "start complete"
