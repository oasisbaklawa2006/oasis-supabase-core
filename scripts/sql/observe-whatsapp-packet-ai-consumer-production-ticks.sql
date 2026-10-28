-- Read-only observation of scheduler-submitted consumer ticks. Run with
-- `psql -X -q -t -A -v ON_ERROR_STOP=1 -f`: emits exactly one JSON array of the pg_net responses
-- recorded in the last three hours. The release instant is applied by the evaluator, not here, so this
-- file takes no parameter and is plain SQL. A request older than the window is simply absent, which
-- the evaluator treats as a missing tick (fail closed).
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
WHERE created >= now() - interval '3 hours';
ROLLBACK;
