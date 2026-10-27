/** Test-only `serve` replacement: binds the webhook handler to WEBHOOK_TEST_PORT. */
export function serve(
  handler: (req: Request) => Response | Promise<Response>,
): Deno.HttpServer {
  const port = Number(Deno.env.get("WEBHOOK_TEST_PORT"));
  return Deno.serve({ port, hostname: "127.0.0.1", onListen() {} }, handler);
}
