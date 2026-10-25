-- Read-only production data-change snapshot used to prove a consumer release changed no queue,
-- dead-letter or outbound-attempt data. Run with `psql -X -q -t -A -v ON_ERROR_STOP=1 -f`: emits exactly
-- one JSON object.
-- It runs as the least-privilege release role, which cannot read business tables, so it reads the
-- cumulative row-change counters PostgreSQL keeps per table (inserts, updates, deletes). Counts only: no
-- message content, identity or secret. A counter that moves, or that drops after a statistics reset,
-- is treated as a change (fail closed). Table emptying via the bulk-clear command is not counted as row deletes, so each table's relfilenode
-- is recorded too: it changes on a bulk clear and on a table rewrite, so those are detected as well.
BEGIN READ ONLY;
SELECT json_build_object(
  'capturedAt', clock_timestamp(),
  'tableDml', (
    SELECT coalesce(
      json_object_agg(
        s.relname,
        json_build_object('ins', s.n_tup_ins, 'upd', s.n_tup_upd, 'del', s.n_tup_del, 'relfilenode', c.relfilenode)
      ),
      '{}'::json
    )
    FROM pg_stat_user_tables s
    JOIN pg_class c ON c.oid = s.relid
    WHERE s.schemaname = 'public'
      AND s.relname IN (
        'whatsapp_packet_ai_dispatch_jobs',
        'dead_letter_entries',
        'whatsapp_case_outbound_attempts',
        'whatsapp_case_events',
        'whatsapp_case_department_tasks'
      )
  )
);
ROLLBACK;
