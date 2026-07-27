-- Phase 2G: bridge cursor + run audit (Studio-owned, read/write via service role only)

CREATE TABLE IF NOT EXISTS public.whatsapp_studio_inbox_bridge_state (
  id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  last_erp_cursor TIMESTAMPTZ NOT NULL DEFAULT '1970-01-01T00:00:00Z',
  last_erp_row_id TEXT,
  last_run_at TIMESTAMPTZ,
  last_run_rows_read INT NOT NULL DEFAULT 0,
  last_run_rows_ingested INT NOT NULL DEFAULT 0,
  last_run_rows_duplicate INT NOT NULL DEFAULT 0,
  last_run_rows_skipped INT NOT NULL DEFAULT 0,
  last_run_rows_failed INT NOT NULL DEFAULT 0,
  last_error TEXT,
  last_run_errors JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.whatsapp_studio_inbox_bridge_state IS
  'Phase 2G ERP→Studio inbox bridge cursor. Service role only; no operator UI.';

ALTER TABLE public.whatsapp_studio_inbox_bridge_state ENABLE ROW LEVEL SECURITY;

INSERT INTO public.whatsapp_studio_inbox_bridge_state (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;
