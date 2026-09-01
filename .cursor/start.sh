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
#   3. Make the Docker socket usable by the agent user via a scoped ACL.
#
# Any failure of a required step aborts with a non-zero exit so a broken boot is
# visible rather than silently degraded.
set -euo pipefail

log() { echo "START: $*"; }

# --- 1. Bridge networking fix ----------------------------------------------
sudo modprobe br_netfilter 2>/dev/null || true
if [ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
  # br_netfilter is active, so bridged traffic would traverse iptables. It MUST
  # be disabled for container<->container connectivity; fail loudly otherwise.
  if ! sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 \
     || [ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null)" != "0" ]; then
    echo "START: ERROR: could not disable net.bridge.bridge-nf-call-iptables" >&2
    exit 1
  fi
  sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true
fi
# If the bridge-nf sysctl path is absent, br_netfilter is not filtering bridged
# traffic at all, so no fix is needed.
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

# --- 3. Docker socket access (scoped, not world-writable) -------------------
# `usermod -aG docker` (install.sh) only takes effect in a fresh login session,
# so also grant the current agent user access directly with a POSIX ACL. This
# is scoped to one user and avoids making the socket world-writable (which would
# be root-equivalent access for every process on the VM).
if [ -S /var/run/docker.sock ]; then
  agent_user="$(id -un)"
  if [ "$agent_user" != "root" ]; then
    if ! sudo setfacl -m "u:${agent_user}:rw" /var/run/docker.sock 2>/dev/null; then
      # Fall back to the docker group if ACLs are unavailable on this fs.
      sudo chgrp docker /var/run/docker.sock 2>/dev/null || true
      sudo chmod 660 /var/run/docker.sock 2>/dev/null || true
    fi
    if ! docker info >/dev/null 2>&1; then
      echo "START: ERROR: docker socket is not accessible to ${agent_user} without sudo" >&2
      exit 1
    fi
  fi
fi

log "start complete"
