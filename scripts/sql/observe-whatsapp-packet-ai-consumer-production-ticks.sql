-- Read-only observation of scheduler-submitted consumer ticks since a caller-supplied
-- instant (psql variable `since`). Emits one JSON array of recorded pg_net responses.
-- Only status, timestamp and the consumer's own result body are read.
BEGIN READ ONLY;
\pset tuples_only on
\pset format unaligned
SELECT coalesce(
  json_agg(
    json_build_object('id', id, 'status', status_code, 'created', created, 'content', content)
    ORDER BY created
  ),
  '[]'::json
)
FROM net._http_response
WHERE created >= :'since'::timestamptz;
ROLLBACK;
