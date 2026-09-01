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
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true
  sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true
fi
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# --- 2. Docker daemon -------------------------------------------------------
if sudo docker info >/dev/null 2>&1; then
  log "docker daemon already running"
else
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

# --- 3. Docker socket access ------------------------------------------------
# Make the socket usable by the agent user without sudo. `usermod -aG docker`
# (in install.sh) only takes effect in a fresh login session, so widen the
# socket permissions directly; this is a single-user local dev VM.
if [ -S /var/run/docker.sock ]; then
  sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
fi

log "start complete"
