-- Read-only production database prerequisites for the gifting-enquiries first deploy.
-- Must not mutate schema, data, secrets, or auth identities.

BEGIN READ ONLY;

\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.gifting_enquiry_receive_v1(text,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'gifting_enquiry_receive_v1 RPC is missing';
  END IF;
  IF to_regclass('public.gifting_enquiries') IS NULL THEN
    RAISE EXCEPTION 'gifting_enquiries table is missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.connect_profiles WHERE profile_key = 'gifting_enquiries_v1'
  ) THEN
    RAISE EXCEPTION 'gifting_enquiries_v1 Connect profile is missing';
  END IF;
  IF to_regprocedure('public.connect_admin_issue_token_v1(uuid,text[],text,timestamp with time zone,integer)') IS NULL THEN
    RAISE EXCEPTION 'connect_admin_issue_token_v1 is missing';
  END IF;
END $$;

SELECT 'GIFTING_ENQUIRIES_DB_PREREQ_OK' AS status;

COMMIT;
