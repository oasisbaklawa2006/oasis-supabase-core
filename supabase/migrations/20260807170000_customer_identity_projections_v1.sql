-- Tranche B: thin governed customer identity projections for the B2B Buyer App.
-- Authority chain: auth.users -> public.profiles -> public.companies
-- (matches buyer_product_prices_v1 / customer_order_status_v1 family).

-- ══════════════════════════════════════════════════════════════════════
-- Shared eligible-buyer gate (profiles-based; never client company_id)
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.customer_buyer_eligible_company_id()
returns uuid
language sql
stable
security definer
set search_path to pg_catalog, public, auth
as $$
  select p.company_id
  from public.profiles p
  join public.companies c on c.id = p.company_id
  where p.id = auth.uid()
    and p.company_id is not null
    and p.is_approved is true
    and lower(coalesce(p.status, '')) = 'approved'
    and lower(coalesce(p.role, '')) in ('b2b_buyer', 'buyer')
    and not public.is_staff_role(p.role)
    and not coalesce(public.is_internal_staff(auth.uid()), false)
    and lower(coalesce(c.status, '')) in ('active', 'approved')
    and coalesce(c.is_frozen, false) is false
  limit 1;
$$;

comment on function public.customer_buyer_eligible_company_id() is
  'Returns the authenticated approved buyer company_id from profiles for allowed buyer roles only (b2b_buyer, buyer). Excludes internal staff regardless of company_id. Fail-closed identity gate for customer-app RPCs.';

revoke all on function public.customer_buyer_eligible_company_id() from public, anon;
grant execute on function public.customer_buyer_eligible_company_id() to authenticated, service_role;

-- ══════════════════════════════════════════════════════════════════════
-- customer_company_v1 — buyer-safe company projection
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.customer_company_v1()
returns table (
  company_id uuid,
  business_name text,
  gst_number text,
  status text,
  price_tier text,
  payment_terms text,
  registered_address text,
  phone text,
  is_frozen boolean
)
language sql
stable
security definer
set search_path to pg_catalog, public, auth
as $$
  with eligible as (
    select public.customer_buyer_eligible_company_id() as company_id
  )
  select
    c.id as company_id,
    c.business_name,
    nullif(btrim(c.gst_number), '') as gst_number,
    c.status,
    nullif(btrim(c.price_tier), '') as price_tier,
    c.payment_terms,
    nullif(btrim(c.registered_address), '') as registered_address,
    nullif(btrim(c.phone), '') as phone,
    coalesce(c.is_frozen, false) as is_frozen
  from eligible e
  join public.companies c on c.id = e.company_id
  where e.company_id is not null;
$$;

comment on function public.customer_company_v1() is
  'Buyer-safe company projection for the authenticated approved buyer. Company resolved exclusively from profiles; no client-supplied company_id.';

revoke all on function public.customer_company_v1() from public, anon;
grant execute on function public.customer_company_v1() to authenticated, service_role;

-- ══════════════════════════════════════════════════════════════════════
-- customer_team_v1 — approved colleagues in the same company
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.customer_team_v1()
returns table (
  profile_id uuid,
  full_name text,
  email text,
  mobile_number text,
  role text,
  status text
)
language sql
stable
security definer
set search_path to pg_catalog, public, auth
as $$
  with eligible as (
    select public.customer_buyer_eligible_company_id() as company_id
  )
  select
    p.id as profile_id,
    nullif(btrim(p.full_name), '') as full_name,
    nullif(btrim(p.email), '') as email,
    nullif(btrim(p.mobile_number), '') as mobile_number,
    p.role,
    p.status
  from eligible e
  join public.profiles p on p.company_id = e.company_id
  where e.company_id is not null
    and p.is_approved is true
    and lower(coalesce(p.status, '')) = 'approved'
    and lower(coalesce(p.role, '')) in ('b2b_buyer', 'buyer', 'pending_buyer')
  order by p.full_name nulls last, p.email, p.id;
$$;

comment on function public.customer_team_v1() is
  'Buyer-safe team projection: approved buyer profiles in the caller company. No cross-company disclosure; no internal staff or accounting fields.';

revoke all on function public.customer_team_v1() from public, anon;
grant execute on function public.customer_team_v1() to authenticated, service_role;
