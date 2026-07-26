// Mock upstream backend for the `zigapagos serve --proxy` e2e (tests/serve/proxy.sh).
//
// Binds 127.0.0.1:0 (an ephemeral free port) and prints `PORT=<n>` on the first
// line of stdout so the test harness can discover it. Exposes:
//   GET  /api/echo  -> JSON echo of method/path + the X-Forwarded-For it saw,
//                      with `Set-Cookie: sid=abc` (cookie relay assertion).
//   POST /api/echo  -> echoes the request body verbatim, plus `x-echo-cookie`
//                      reflecting the received Cookie header (request-cookie
//                      round-trip assertion) and `Set-Cookie: sid=abc`.
//   GET  /api/sse   -> text/event-stream: emits "event 1", waits 300ms, emits
//                      "event 2", then closes (streaming-not-buffered assertion).
// Anything else -> 404.

// The EXACT request-line target as received (Bun preserves the raw, still
// percent-encoded target in req.url). Reconstructing via `new URL().pathname +
// search` would normalise it and defeat the C1 raw-target assertion, so slice
// it straight out of the URL string instead.
function rawTarget(req: Request): string {
  const u = req.url;
  const schemeEnd = u.indexOf("://");
  const pathStart = schemeEnd === -1 ? u.indexOf("/") : u.indexOf("/", schemeEnd + 3);
  return pathStart === -1 ? "/" : u.slice(pathStart);
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/api/echo") {
      if (req.method === "POST") {
        const body = await req.text();
        return new Response(body, {
          headers: {
            "content-type": "text/plain",
            "set-cookie": "sid=abc; Path=/",
            "x-echo-cookie": req.headers.get("cookie") ?? "",
            "x-echo-method": "POST",
          },
        });
      }
      return new Response(
        JSON.stringify({
          method: req.method,
          path: url.pathname,
          // The raw request-line target upstream actually saw (locks C1: the
          // proxy must forward the still-encoded target, not a decoded copy).
          target: rawTarget(req),
          xff: req.headers.get("x-forwarded-for") ?? "",
          xproto: req.headers.get("x-forwarded-proto") ?? "",
        }),
        {
          headers: {
            "content-type": "application/json",
            "set-cookie": "sid=abc; Path=/",
          },
        },
      );
    }

    if (url.pathname === "/api/sse") {
      const stream = new ReadableStream({
        async start(controller) {
          const enc = new TextEncoder();
          controller.enqueue(enc.encode("event: msg\ndata: event 1\n\n"));
          await new Promise((r) => setTimeout(r, 300));
          controller.enqueue(enc.encode("event: msg\ndata: event 2\n\n"));
          controller.close();
        },
      });
      return new Response(stream, {
        headers: {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
        },
      });
    }

    return new Response("mock upstream: not found\n", { status: 404 });
  },
});

console.log(`PORT=${server.port}`);
