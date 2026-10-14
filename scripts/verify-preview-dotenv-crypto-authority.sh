#!/usr/bin/env bash
# Fail-closed authority check for the committed, dotenvx-encrypted
# supabase/.env.preview. The ONLY accepted authorities are:
#
#   1. An independently held private key (PREVIEW_DOTENV_PRIVATE_KEY, supplied
#      from a protected GitHub secret): its derived public key must equal the
#      file header AND dotenvx must decrypt both entries with it.
#   2. When no independent key is held: a narrow historical executor
#      attestation for this exact blob (scripts/verify-preview-dotenv-attestation.py).
#
# The Supabase Management API is never consulted: it does not return stored
# secret values, so anything read back from it is not a private key. Secret
# names or timestamps are never treated as proof of key identity. A key that is
# supplied but wrong fails closed; it can never fall through to an attestation.
#
# Prints machine-readable status lines only; never prints key material.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

preview_file="supabase/.env.preview"
keys_file="supabase/.env.keys"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "PREVIEW_DOTENV_AUTHORITY_FAILED: $*" >&2
  exit 1
}

[[ -f "$preview_file" ]] || fail "ENV_PREVIEW_MISSING"
grep -Eq '^GEMINI_API_KEY="?encrypted:' "$preview_file" || fail "GEMINI_API_KEY_NOT_ENCRYPTED"
grep -Eq '^WA_STAGE1B_CERT_SECRET="?encrypted:' "$preview_file" || fail "WA_STAGE1B_CERT_SECRET_NOT_ENCRYPTED"

header_public_key="$({ grep -E '^DOTENV_PUBLIC_KEY_PREVIEW=' "$preview_file" || true; } | head -n 1 | cut -d= -f2- | tr -d "\"' \r" | tr 'A-F' 'a-f')"
[[ "$header_public_key" =~ ^0[23][0-9a-f]{64}$ ]] || fail "PUBLIC_KEY_HEADER_MISSING_OR_INVALID"

if [[ -n "${PREVIEW_DOTENV_PRIVATE_KEY:-}" ]]; then
  echo "::add-mask::${PREVIEW_DOTENV_PRIVATE_KEY}" >&2
  [[ "$PREVIEW_DOTENV_PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]] || fail "KEY_FORMAT_INVALID"

  derived_public_key="$(printf '%s' "$PREVIEW_DOTENV_PRIVATE_KEY" | node -e '
const crypto = require("node:crypto");
let input = "";
process.stdin.on("data", (chunk) => { input += chunk; }).on("end", () => {
  try {
    const ecdh = crypto.createECDH("secp256k1");
    ecdh.setPrivateKey(Buffer.from(input.trim(), "hex"));
    process.stdout.write(ecdh.getPublicKey("hex", "compressed").toLowerCase());
  } catch (_) {
    process.exit(4);
  }
});
')" || fail "KEY_INVALID"

  [[ "$derived_public_key" == "$header_public_key" ]] || fail "PUBLIC_KEY_MISMATCH"

  created_keys_file=false
  [[ -e "$keys_file" ]] || created_keys_file=true
  if ! bash "$script_dir/verify-preview-env-decryptable.sh" >/dev/null 2>&1; then
    [[ "$created_keys_file" == false ]] || rm -f "$keys_file"
    fail "DECRYPT_FAILED"
  fi
  [[ "$created_keys_file" == false ]] || rm -f "$keys_file"
  echo "authority_mode=independent_key"
  exit 0
fi

if python3 "$script_dir/verify-preview-dotenv-attestation.py" >&2; then
  echo "::warning::PREVIEW_DOTENV_AUTHORITY_ATTESTED_HISTORICAL_BLOB independent key custody is not established; hosted Supabase Preview and Edge Runtime readiness remain mandatory." >&2
  echo "authority_mode=attested_blob"
  exit 0
fi

fail "KEY_CUSTODY_UNAVAILABLE"
