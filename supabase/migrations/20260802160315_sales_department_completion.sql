-- Central v1.0: complete the bounded B2B Sales department schema.
-- These tables own relationship work only; Central transaction tables remain authoritative.

CREATE TABLE IF NOT EXISTS public.sales_relationships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  sales_exec_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  relationship_role text NOT NULL DEFAULT 'primary' CHECK (relationship_role IN ('primary', 'supporting')),
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz,
  change_reason text,
  changed_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at IS NULL OR ends_at >= starts_at)
);

CREATE TABLE IF NOT EXISTS public.follow_up_snoozes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.crm_tasks(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  snoozed_by uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  previous_due_date date NOT NULL,
  snoozed_until date NOT NULL,
  reason_code text NOT NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (snoozed_until > previous_due_date)
);

CREATE TABLE IF NOT EXISTS public.reorder_alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  sales_exec_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  last_order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  expected_on date NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'contacted', 'snoozed', 'converted', 'dismissed')),
  reason_code text NOT NULL,
  snoozed_until date,
  contacted_at timestamptz,
  resolved_at timestamptz,
  resolution_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.sales_escalations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  sales_exec_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  task_id uuid REFERENCES public.crm_tasks(id) ON DELETE SET NULL,
  ticket_id uuid REFERENCES public.support_tickets(id) ON DELETE SET NULL,
  escalation_type text NOT NULL CHECK (escalation_type IN ('missed_follow_up', 'unresolved_ticket', 'order_delay', 'payment_block', 'customer_risk', 'dispatch_exception')),
  severity text NOT NULL DEFAULT 'normal' CHECK (severity IN ('low', 'normal', 'high', 'critical')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved', 'dismissed')),
  reason text NOT NULL,
  assigned_to uuid REFERENCES public.users(id) ON DELETE SET NULL,
  resolution_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.customer_contact_preferences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  preferred_channel text NOT NULL DEFAULT 'whatsapp' CHECK (preferred_channel IN ('call', 'whatsapp', 'sms', 'email', 'app')),
  preferred_language text,
  preferred_contact_window text,
  opt_out_marketing boolean NOT NULL DEFAULT false,
  notes text,
  recorded_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id)
);

CREATE INDEX IF NOT EXISTS idx_sales_relationships_company_active ON public.sales_relationships(company_id, ends_at);
CREATE INDEX IF NOT EXISTS idx_sales_relationships_exec_active ON public.sales_relationships(sales_exec_id, ends_at);
CREATE INDEX IF NOT EXISTS idx_follow_up_snoozes_task ON public.follow_up_snoozes(task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reorder_alerts_exec_status ON public.reorder_alerts(sales_exec_id, status, expected_on);
CREATE INDEX IF NOT EXISTS idx_reorder_alerts_company ON public.reorder_alerts(company_id, status);
CREATE INDEX IF NOT EXISTS idx_sales_escalations_status ON public.sales_escalations(status, severity, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_escalations_exec ON public.sales_escalations(sales_exec_id, status);

ALTER TABLE public.sales_relationships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.follow_up_snoozes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reorder_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_escalations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_contact_preferences ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Sales read assigned relationships" ON public.sales_relationships FOR SELECT TO authenticated
  USING (sales_exec_id = auth.uid() OR is_account_manager(auth.uid(), company_id) OR is_internal_staff(auth.uid()));
CREATE POLICY "Managers manage relationships" ON public.sales_relationships FOR ALL TO authenticated
  USING (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'SALES_MANAGER'))
  WITH CHECK (get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'SALES_MANAGER'));

CREATE POLICY "Sales manage own snoozes" ON public.follow_up_snoozes FOR ALL TO authenticated
  USING (snoozed_by = auth.uid() OR is_account_manager(auth.uid(), company_id) OR is_internal_staff(auth.uid()))
  WITH CHECK (snoozed_by = auth.uid() OR is_account_manager(auth.uid(), company_id));

CREATE POLICY "Sales read assigned reorder alerts" ON public.reorder_alerts FOR SELECT TO authenticated
  USING (sales_exec_id = auth.uid() OR is_account_manager(auth.uid(), company_id) OR is_internal_staff(auth.uid()));
CREATE POLICY "Sales update assigned reorder alerts" ON public.reorder_alerts FOR UPDATE TO authenticated
  USING (sales_exec_id = auth.uid() OR is_account_manager(auth.uid(), company_id) OR get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'SALES_MANAGER'))
  WITH CHECK (sales_exec_id = auth.uid() OR is_account_manager(auth.uid(), company_id) OR get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'SALES_MANAGER'));

CREATE POLICY "Staff read sales escalations" ON public.sales_escalations FOR SELECT TO authenticated
  USING (sales_exec_id = auth.uid() OR assigned_to = auth.uid() OR is_internal_staff(auth.uid()));
CREATE POLICY "Sales create escalations" ON public.sales_escalations FOR INSERT TO authenticated
  WITH CHECK (sales_exec_id = auth.uid() OR is_account_manager(auth.uid(), company_id));
CREATE POLICY "Managers resolve escalations" ON public.sales_escalations FOR UPDATE TO authenticated
  USING (assigned_to = auth.uid() OR get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'SALES_MANAGER'))
  WITH CHECK (assigned_to = auth.uid() OR get_user_role(auth.uid()) IN ('ADMIN', 'SUPER_ADMIN', 'SALES_MANAGER'));

CREATE POLICY "Sales read contact preferences" ON public.customer_contact_preferences FOR SELECT TO authenticated
  USING (is_account_manager(auth.uid(), company_id) OR is_internal_staff(auth.uid()));
CREATE POLICY "Sales manage contact preferences" ON public.customer_contact_preferences FOR INSERT TO authenticated
  WITH CHECK (is_account_manager(auth.uid(), company_id) OR recorded_by = auth.uid());
CREATE POLICY "Sales update contact preferences" ON public.customer_contact_preferences FOR UPDATE TO authenticated
  USING (is_account_manager(auth.uid(), company_id) OR recorded_by = auth.uid())
  WITH CHECK (is_account_manager(auth.uid(), company_id) OR recorded_by = auth.uid());
