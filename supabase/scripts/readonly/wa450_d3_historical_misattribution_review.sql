-- WA450-D3 READ-ONLY review query (do not execute without owner authorization).
-- Surfaces WhatsApp cases where resolution likely relied on message GSTIN clues
-- without a matching sender phone / delivery-address binding to the same company.
-- Data review and any corrective action require separate human authorization.

-- Adjust the time window before running in a governed review session.
with resolution_events as (
  select
    wcc.id as case_id,
    wcc.created_at,
    wcc.company_id,
    wc.phone_number as sender_phone,
    coalesce(
      wcc.metadata->>'match_method',
      wcc.metadata->'identity'->>'match_method',
      wcc.metadata->>'resolution_match_method'
    ) as match_method
  from public.whatsapp_communication_cases wcc
  join public.whatsapp_contacts wc on wc.id = wcc.contact_id
  where wcc.created_at >= timestamptz '2026-01-01'
    and wcc.company_id is not null
),
gst_clue_resolutions as (
  select *
  from resolution_events
  where match_method in ('EXACT_GST_MATCH', 'EXACT_NAME_MATCH', 'PROGRESSIVE_NAME_LOCATION_PERSON_MATCH')
),
sender_bindings as (
  select
    g.case_id,
    g.created_at,
    g.company_id,
    g.sender_phone,
    g.match_method,
    exists (
      select 1
      from public.companies c
      where c.id = g.company_id
        and length(regexp_replace(coalesce(g.sender_phone, ''), '\D', '', 'g')) >= 10
        and (
          lower(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'))
            = lower(regexp_replace(coalesce(g.sender_phone, ''), '\D', '', 'g'))
          or exists (
            select 1 from public.delivery_addresses da
            where da.company_id = c.id
              and lower(regexp_replace(coalesce(da.contact_phone, ''), '\D', '', 'g'))
                = lower(regexp_replace(coalesce(g.sender_phone, ''), '\D', '', 'g'))
          )
          or exists (
            select 1 from public.b2b_applications ba
            where ba.status = 'approved'
              and upper(regexp_replace(coalesce(ba.gst_number, ''), '\s', '', 'g'))
                = upper(regexp_replace(coalesce(c.gst_number, ''), '\s', '', 'g'))
              and (
                lower(regexp_replace(coalesce(ba.contact_phone, ''), '\D', '', 'g'))
                  = lower(regexp_replace(coalesce(g.sender_phone, ''), '\D', '', 'g'))
                or lower(regexp_replace(coalesce(ba.mobile_number, ''), '\D', '', 'g'))
                  = lower(regexp_replace(coalesce(g.sender_phone, ''), '\D', '', 'g'))
              )
          )
        )
    ) as sender_phone_bound_to_company,
    exists (
      select 1
      from public.whatsapp_sender_commercial_authorizations a
      join public.whatsapp_contacts wc on wc.id = a.contact_id
      where wc.phone_number = g.sender_phone
        and a.company_id = g.company_id
        and a.authorized_at is not null
        and a.authorized_at <= g.created_at
        and a.valid_until > g.created_at
        and (a.revoked_at is null or a.revoked_at > g.created_at)
    ) as had_active_delegated_auth_at_intake
  from gst_clue_resolutions g
)
select
  case_id,
  created_at,
  company_id,
  sender_phone,
  match_method
from sender_bindings
where not sender_phone_bound_to_company
  and not had_active_delegated_auth_at_intake
order by created_at desc;
