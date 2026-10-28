/**
 * Test-only stand-in for `serve` from deno.land/std. It lets index.test.ts run the
 * real consumer entrypoint as a subprocess on a caller-chosen port without any
 * remote module download. It is never part of the deployed bundle.
 */
export function serve(
  handler: (req: Request) => Response | Promise<Response>,
): Deno.HttpServer {
  const port = Number(Deno.env.get("CONSUMER_TEST_PORT"));
  return Deno.serve({ port, hostname: "127.0.0.1", onListen() {} }, handler);
}
