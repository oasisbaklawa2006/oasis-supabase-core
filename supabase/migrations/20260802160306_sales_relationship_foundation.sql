-- Central v1.0: bounded B2B Sales Relationship foundation.
-- Relationship records are extraction-ready for Oasis CRM v2.0; Central remains
-- authoritative for orders, payments, production, QC, invoices and dispatch.

ALTER TABLE public.crm_tasks
  ADD COLUMN IF NOT EXISTS reason_code text,
  ADD COLUMN IF NOT EXISTS snooze_reason text,
  ADD COLUMN IF NOT EXISTS snoozed_until date,
  ADD COLUMN IF NOT EXISTS last_action_at timestamptz,
  ADD COLUMN IF NOT EXISTS linked_order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL;

ALTER TABLE public.client_interactions
  ADD COLUMN IF NOT EXISTS channel text DEFAULT 'other',
  ADD COLUMN IF NOT EXISTS reason_code text,
  ADD COLUMN IF NOT EXISTS next_action text,
  ADD COLUMN IF NOT EXISTS next_action_date date,
  ADD COLUMN IF NOT EXISTS linked_order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS linked_ticket_id uuid REFERENCES public.support_tickets(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.sales_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  requested_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  request_type text NOT NULL CHECK (request_type IN ('credit', 'special_price', 'production_priority', 'qc_intervention', 'packing_correction', 'dispatch_correction')),
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn', 'completed')),
  requested_amount numeric,
  requested_price numeric,
  product_id uuid REFERENCES public.products(id) ON DELETE SET NULL,
  reason text NOT NULL,
  supporting_notes text,
  decision_notes text,
  decided_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  decided_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.customer_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  ticket_id uuid REFERENCES public.support_tickets(id) ON DELETE SET NULL,
  collected_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  rating smallint CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),
  feedback text,
  category text,
  requires_action boolean NOT NULL DEFAULT false,
  action_task_id uuid REFERENCES public.crm_tasks(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.sales_performance_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_exec_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  task_id uuid REFERENCES public.crm_tasks(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  outcome text NOT NULL DEFAULT 'neutral' CHECK (outcome IN ('positive', 'negative', 'neutral', 'excluded')),
  score_delta numeric NOT NULL DEFAULT 0,
  attribution_reason text NOT NULL,
  verified_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.sales_commission_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_exec_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  event_type text NOT NULL CHECK (event_type IN ('projected', 'earned', 'held', 'adjusted', 'paid', 'reversed')),
  amount numeric NOT NULL DEFAULT 0,
  reason text NOT NULL,
  created_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_requests_company_status ON public.sales_requests(company_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_requests_requester ON public.sales_requests(requested_by, status);
CREATE INDEX IF NOT EXISTS idx_customer_feedback_company ON public.customer_feedback(company_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_perf_exec_date ON public.sales_performance_events(sales_exec_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_commission_exec_order ON public.sales_commission_events(sales_exec_id, order_id, created_at DESC);

ALTER TABLE public.sales_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_performance_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_commission_events ENABLE ROW LEVEL SECURITY;

-- Sales may create/read their assigned relationship records, but approval remains
-- with authorised Central departments and management.
CREATE POLICY "Sales read assigned requests" ON public.sales_requests FOR SELECT TO authenticated
  USING (is_account_manager(auth.uid(), company_id) OR requested_by = auth.uid() OR is_internal_staff(auth.uid()));
CREATE POLICY "Sales create assigned requests" ON public.sales_requests FOR INSERT TO authenticated
  WITH CHECK (is_account_manager(auth.uid(), company_id) OR requested_by = auth.uid());
CREATE POLICY "Approvers manage sales requests" ON public.sales_requests FOR UPDATE TO authenticated
  USING (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'FINANCE_HEAD', 'PRODUCTION_HEAD', 'QC_HEAD', 'DISPATCH_HEAD'))
  WITH CHECK (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'FINANCE_HEAD', 'PRODUCTION_HEAD', 'QC_HEAD', 'DISPATCH_HEAD'));

CREATE POLICY "Sales read assigned feedback" ON public.customer_feedback FOR SELECT TO authenticated
  USING (is_account_manager(auth.uid(), company_id) OR is_internal_staff(auth.uid()));
CREATE POLICY "Sales create assigned feedback" ON public.customer_feedback FOR INSERT TO authenticated
  WITH CHECK (is_account_manager(auth.uid(), company_id) OR collected_by = auth.uid());

CREATE POLICY "Staff read performance events" ON public.sales_performance_events FOR SELECT TO authenticated
  USING (sales_exec_id = auth.uid() OR is_internal_staff(auth.uid()));
CREATE POLICY "Managers manage performance events" ON public.sales_performance_events FOR ALL TO authenticated
  USING (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'FINANCE_HEAD'))
  WITH CHECK (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'FINANCE_HEAD'));

CREATE POLICY "Staff read commission events" ON public.sales_commission_events FOR SELECT TO authenticated
  USING (sales_exec_id = auth.uid() OR is_internal_staff(auth.uid()));
CREATE POLICY "Finance manage commission events" ON public.sales_commission_events FOR ALL TO authenticated
  USING (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'FINANCE_HEAD'))
  WITH CHECK (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'FINANCE_HEAD'));
