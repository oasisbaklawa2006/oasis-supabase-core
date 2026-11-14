-- Import-ready DRAFT carton configurations (owner-specified technical values). NOT RUN anywhere.
-- Inserts three rows in approval_status 'draft': they are invisible to buyers until Operations/Core approve them with an approver and evidence.
-- Dimensions are deliberately NOT stored here (the governance tables hold slot counts only); see carton_physical_reference.csv.
-- slot_columns/slot_rows stay NULL because no physical arrangement has been verified by a pack-and-close trial.
-- No SKU mapping, price, unit or approval is invented: product_packing_profiles gets no rows from this script.
begin;
insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, asset_status, approval_status) values
  ('888x4',   1, 'Type A — 888×4',     'bulk_sweets',  4, 'tray', 'missing', 'draft'),
  ('bulk-6',  1, 'Type B — 666×6',     'bulk_sweets',  6, 'box',  'missing', 'draft'),
  ('bulk-10', 1, 'Type C — RTC1×10',   'bulk_sweets', 10, 'tray', 'missing', 'draft')
on conflict (config_id, config_version) do nothing;
-- post-import checks (expect 3 draft rows, none approved)
select config_id, config_version, capacity_slots, inner_pack, approval_status from public.carton_configurations where config_id in ('888x4','bulk-6','bulk-10') order by config_id;
commit;
