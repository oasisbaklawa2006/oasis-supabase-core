-- Clean-replay compatibility baseline for the legacy support-ticket tables.
-- Production already contained these tables before the governed migration chain.

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  order_id text,
  user_id uuid,
  created_by uuid,
  issue_type text,
  description text,
  product_sku text,
  qty_affected integer,
  status text not null default 'open',
  resolution_notes text,
  routed_to_department text,
  assigned_employee_id uuid,
  sla_first_response_at timestamptz,
  sla_action_at timestamptz,
  sla_resolved_at timestamptz,
  sla_state text,
  sla_first_response_due timestamptz,
  sla_resolution_due timestamptz,
  estimated_financial_loss numeric,
  admin_rating_speed integer,
  admin_rating_quality integer,
  admin_rating_communication integer,
  rejection_reason_template text,
  resolution_template_used text,
  ai_rewritten_reply text,
  escalated_to_hod boolean not null default false,
  commission_blocked boolean not null default false,
  customer_rating integer,
  created_at timestamptz not null default now()
);

create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now()
);
