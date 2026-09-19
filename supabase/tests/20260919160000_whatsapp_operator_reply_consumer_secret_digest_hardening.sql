-- Contract coverage for:
-- 20260919160000_whatsapp_operator_reply_consumer_secret_digest_hardening.sql

begin;
select plan(5);

select ok(
  (select prosecdef from pg_proc where oid = 'public.verify_whatsapp_operator_reply_consumer_secret(text)'::regprocedure),
  'consumer secret verifier remains SECURITY DEFINER'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog']
   from pg_proc where oid = 'public.verify_whatsapp_operator_reply_consumer_secret(text)'::regprocedure),
  'consumer secret verifier uses a minimal fixed search_path'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.verify_whatsapp_operator_reply_consumer_secret(text)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'public.verify_whatsapp_operator_reply_consumer_secret(text)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.verify_whatsapp_operator_reply_consumer_secret(text)',
    'EXECUTE'
  ),
  'consumer secret verifier remains service-role only'
);

select ok(
  public.verify_whatsapp_operator_reply_consumer_secret(
    (
      select decrypted_secret
      from vault.decrypted_secrets
      where name='whatsapp_operator_reply_consumer_v1'
      order by created_at desc
      limit 1
    )
  ),
  'exact Vault machine secret is accepted'
);

with s as (
  select decrypted_secret as secret
  from vault.decrypted_secrets
  where name='whatsapp_operator_reply_consumer_v1'
  order by created_at desc
  limit 1
)
select ok(
  not public.verify_whatsapp_operator_reply_consumer_secret(
    case
      when substring(secret,1,1)='0'
        then '1' || substring(secret from 2)
      else '0' || substring(secret from 2)
    end
  )
  and not public.verify_whatsapp_operator_reply_consumer_secret('too-short'),
  'same-length wrong digest and short candidate are both rejected'
)
from s;

select * from finish();
rollback;
