// Sends a keep-alive body-method request with NO Content-Length and NO
// Transfer-Encoding over a raw TCP socket, then waits for a response WITHOUT
// half-closing the write side — i.e. a real keep-alive client holding the
// socket open. On the pre-fix server this hangs (std's bodyReader reads the
// "body" until close) or aborts the process (discardBody assert); either way no
// HTTP response arrives and this exits non-zero. On the fixed server the proxy
// forwards `content-length: 0`, relays the upstream response, and closes the
// connection, so we receive a status line and exit 0.
//
// Usage: bun raw-post.ts <port> [method]
const port = Number(process.argv[2]);
const method = process.argv[3] ?? "POST";

let out = "";
let settled = false;
function finish(code: number) {
  if (settled) return;
  settled = true;
  // Emit just the status line for the harness to inspect.
  process.stdout.write((out.split("\r\n")[0] ?? "").trim());
  process.exit(code);
}

await Bun.connect({
  hostname: "127.0.0.1",
  port,
  socket: {
    open(sock) {
      // Keep-alive request (HTTP/1.1, no Connection: close), no framing headers.
      sock.write(`${method} /api/echo HTTP/1.1\r\nHost: raw-test\r\n\r\n`);
    },
    data(_sock, data) {
      out += data.toString();
    },
    close() {
      finish(out.startsWith("HTTP/") ? 0 : 1);
    },
    error() {
      finish(1);
    },
  },
});

// If the server neither responds nor closes (the hang bug), bail as a failure.
setTimeout(() => finish(out.startsWith("HTTP/") ? 0 : 1), 2500);
