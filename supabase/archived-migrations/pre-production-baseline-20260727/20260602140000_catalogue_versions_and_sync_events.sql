-- AI Studio: versioned catalogue snapshots + Central sync event log (additive only)

CREATE TABLE IF NOT EXISTS public.catalogue_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  sku_id uuid NULL,
  version_code text NOT NULL,
  version_number integer NOT NULL,
  snapshot_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'pending_approval', 'approved', 'published', 'synced')),
  approved_by uuid NULL,
  approved_at timestamptz NULL,
  published_at timestamptz NULL,
  synced_to_central_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, version_number)
);

CREATE INDEX IF NOT EXISTS idx_catalogue_versions_product_id
  ON public.catalogue_versions (product_id, version_number DESC);

CREATE TABLE IF NOT EXISTS public.catalogue_sync_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalogue_version_id uuid NOT NULL REFERENCES public.catalogue_versions(id) ON DELETE CASCADE,
  target_system text NOT NULL DEFAULT 'oasis_central',
  sync_status text NOT NULL DEFAULT 'preview_only'
    CHECK (sync_status IN ('preview_only', 'pending', 'success', 'failed')),
  payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message text NULL,
  triggered_by uuid NULL,
  triggered_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_catalogue_sync_events_version
  ON public.catalogue_sync_events (catalogue_version_id, triggered_at DESC);

COMMENT ON TABLE public.catalogue_versions IS
  'Immutable approved catalogue snapshots from AI Studio (Product Truth).';

COMMENT ON TABLE public.catalogue_sync_events IS
  'Central sync preview/export events; preview_only rows do not write to Central.';
