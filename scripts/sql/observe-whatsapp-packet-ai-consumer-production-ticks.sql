-- Read-only observation of scheduler-submitted consumer ticks since a caller-supplied
-- instant (psql variable `since`). Run with `psql -X -q -t -A -v ON_ERROR_STOP=1 -v since=... -f`:
-- emits exactly one JSON array of recorded pg_net responses.
-- Only status, timestamp and the consumer's own result body are read.
BEGIN READ ONLY;
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
