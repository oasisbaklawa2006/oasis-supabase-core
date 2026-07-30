-- Issue #16, tranche A: remove owner-privileged access through legacy public views.
--
-- These views are operational/admin surfaces. Repository caller tracing found no
-- browser client dependency; customer-import validation reaches the import views
-- from controlled database functions. security_invoker makes underlying RLS and
-- grants apply to the actual caller, while the explicit ACL leaves service_role
-- as the sole API role allowed to read the views directly.

alter view public.cmd_department_health
  set (security_invoker = true);
alter view public.v_customer_import_batch_summary
  set (security_invoker = true);
alter view public.v_customer_import_company_phone_slots
  set (security_invoker = true);
alter view public.v_customer_import_company_required_gaps
  set (security_invoker = true);
alter view public.v_customer_import_contact_phone_gaps
  set (security_invoker = true);
alter view public.v_customer_import_duplicate_contact_phone_in_batch
  set (security_invoker = true);
alter view public.v_customer_import_duplicate_gst_in_batch
  set (security_invoker = true);
alter view public.v_customer_import_duplicate_name_in_batch
  set (security_invoker = true);
alter view public.v_customer_import_duplicate_phone_any_in_batch
  set (security_invoker = true);
alter view public.v_customer_import_duplicate_phone_in_batch
  set (security_invoker = true);
alter view public.v_customer_import_gst_match_existing
  set (security_invoker = true);
alter view public.v_customer_import_orphan_contacts
  set (security_invoker = true);
alter view public.v_customer_import_promotion_readiness
  set (security_invoker = true);

revoke all privileges on table
  public.cmd_department_health,
  public.v_customer_import_batch_summary,
  public.v_customer_import_company_phone_slots,
  public.v_customer_import_company_required_gaps,
  public.v_customer_import_contact_phone_gaps,
  public.v_customer_import_duplicate_contact_phone_in_batch,
  public.v_customer_import_duplicate_gst_in_batch,
  public.v_customer_import_duplicate_name_in_batch,
  public.v_customer_import_duplicate_phone_any_in_batch,
  public.v_customer_import_duplicate_phone_in_batch,
  public.v_customer_import_gst_match_existing,
  public.v_customer_import_orphan_contacts,
  public.v_customer_import_promotion_readiness
from public, anon, authenticated, service_role;

grant select on table
  public.cmd_department_health,
  public.v_customer_import_batch_summary,
  public.v_customer_import_company_phone_slots,
  public.v_customer_import_company_required_gaps,
  public.v_customer_import_contact_phone_gaps,
  public.v_customer_import_duplicate_contact_phone_in_batch,
  public.v_customer_import_duplicate_gst_in_batch,
  public.v_customer_import_duplicate_name_in_batch,
  public.v_customer_import_duplicate_phone_any_in_batch,
  public.v_customer_import_duplicate_phone_in_batch,
  public.v_customer_import_gst_match_existing,
  public.v_customer_import_orphan_contacts,
  public.v_customer_import_promotion_readiness
to service_role;
