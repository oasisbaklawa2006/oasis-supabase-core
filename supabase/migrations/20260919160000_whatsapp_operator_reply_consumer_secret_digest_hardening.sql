-- Gate 5b follow-up: harden operator-reply consumer machine-secret verification.
-- Replaces raw text equality with SHA-256 digest equality while preserving the
-- existing minimum-length check and Vault secret authority.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.verify_whatsapp_operator_reply_consumer_secret(
  _candidate text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT coalesce(
    length(coalesce(_candidate, '')) >= 32
    AND extensions.digest(_candidate, 'sha256') = (
      SELECT extensions.digest(decrypted_secret, 'sha256')
      FROM vault.decrypted_secrets
      WHERE name = 'whatsapp_operator_reply_consumer_v1'
      ORDER BY created_at DESC
      LIMIT 1
    ),
    false
  );
$$;

REVOKE ALL ON FUNCTION public.verify_whatsapp_operator_reply_consumer_secret(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_whatsapp_operator_reply_consumer_secret(text)
  TO service_role;

COMMENT ON FUNCTION public.verify_whatsapp_operator_reply_consumer_secret(text) IS
  'Service-role-only verifier for the Vault-backed WhatsApp operator-reply consumer machine secret. Compares SHA-256 digests and rejects candidates shorter than 32 characters.';
