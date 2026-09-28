-- Restore authenticated SELECT on the security-invoker governed Dispatch
-- execution view required by Central /admin/dispatch-mgmt.
--
-- Core #299 / Physical UAT #462: migration 20260822131000 created
-- public.b2b_dispatch_shipment_execution_view with security_invoker=true and
-- relied on underlying RLS, but omitted the view-level GRANT that sibling
-- Dispatch surfaces (b2b_dispatch_command_queue, b2b_dispatch_so_line_fulfilment)
-- received in 20260804103000. PostgreSQL requires both relation privileges
-- and RLS; without the grant, authenticated callers fail before row policies run.
--
-- Keep security_invoker=true so underlying internal-staff RLS remains
-- authoritative. Do not grant anonymous access.

REVOKE ALL ON TABLE public.b2b_dispatch_shipment_execution_view FROM anon;
GRANT SELECT ON TABLE public.b2b_dispatch_shipment_execution_view TO authenticated;
