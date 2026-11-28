#!/usr/bin/env bash
# Install only the PG17 client on the pinned GitHub-hosted Ubuntu 24.04 runner.
# No remote database access, credentials, server installation or restore.
set -euo pipefail
export LC_ALL=C
bin=/usr/lib/postgresql/17/bin
check_clients() {
  local cmd version
  for cmd in psql pg_dump pg_dumpall pg_restore; do
    [[ -x "$bin/$cmd" ]] || return 1
    version="$("$bin/$cmd" --version)" || return 1
    [[ "$version" =~ PostgreSQL\)\ 17\. ]] || return 1
  done
}
if ! check_clients; then
  [[ "$(lsb_release -is)" == Ubuntu && "$(lsb_release -cs)" == noble ]] || {
    echo "::error::QA_PG17_RUNNER_UNSUPPORTED"; exit 1;
  }
  sudo apt-get update
  if ! apt-cache show postgresql-client-17 >/dev/null 2>&1; then
    # Official PostgreSQL package source, with repository-scoped signing key.
    key="$(mktemp)"
    trap 'rm -f -- "$key"' EXIT
    curl --proto '=https' --tlsv1.2 -fsS --retry 3 --output "$key" \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc
    fingerprints="$(gpg --batch --with-colons --show-keys "$key" | awk -F: '$1 == "pub" {primary=1; next} $1 == "fpr" && primary {print $10; primary=0}')"
    [[ "$fingerprints" == B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8 ]] || {
      echo "::error::QA_PG17_REPOSITORY_KEY_MISMATCH"; exit 1;
    }
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo install -m 0644 "$key" /etc/apt/keyrings/genie-qa-pgdg.asc
    echo 'deb [signed-by=/etc/apt/keyrings/genie-qa-pgdg.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main' \
      | sudo tee /etc/apt/sources.list.d/genie-qa-pgdg.list >/dev/null
    sudo apt-get update
  fi
  sudo apt-get install -y --no-install-recommends postgresql-client-17
fi
check_clients || { echo "::error::QA_PG17_CLIENT_VERSION_MISMATCH"; exit 1; }
echo 'QA_PG17_CLIENT_TOOLS_VERIFIED'
