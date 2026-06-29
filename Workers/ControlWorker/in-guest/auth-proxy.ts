import http from "node:http";
import { isAuthorized } from "./auth-proxy-core.js";

const SESSION_TOKEN = process.env.SESSION_TOKEN ?? "";
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT ?? "4321");
const PROXY_PORT = Number(process.env.PROXY_PORT ?? "8080");

if (!SESSION_TOKEN) {
  process.stderr.write(
    "auth-proxy: SESSION_TOKEN not set — refusing to start\n",
  );
  process.exit(1);
}

const server = http.createServer((req, res) => {
  if (!isAuthorized(req.headers.cookie, SESSION_TOKEN)) {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }
  const proxy = http.request(
    {
      host: "127.0.0.1",
      port: UPSTREAM_PORT,
      path: req.url,
      method: req.method,
      headers: req.headers,
    },
    (upstream) => {
      res.writeHead(upstream.statusCode!, upstream.headers);
      upstream.pipe(res);
    },
  );
  proxy.on("error", (err) => {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(
      JSON.stringify({ error: "upstream unavailable", detail: err.message }),
    );
  });
  req.pipe(proxy);
});

server.on("upgrade", (req, socket, head) => {
  if (!isAuthorized(req.headers.cookie, SESSION_TOKEN)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return;
  }
  socket.on("error", () => {});
  const upstream = http.request({
    host: "127.0.0.1",
    port: UPSTREAM_PORT,
    path: req.url,
    method: req.method,
    headers: req.headers,
  });
  upstream.on("upgrade", (upRes, upSocket, upHead) => {
    if (socket.destroyed) return;
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\n${Object.entries(upRes.headers)
        .map(([k, v]) => `${k}: ${v}`)
        .join("\r\n")}\r\n\r\n`,
    );
    if (upHead.length) upSocket.unshift(upHead);
    upSocket.pipe(socket);
    socket.pipe(upSocket);
  });
  upstream.on("error", () => {
    socket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    socket.destroy();
  });
  upstream.end(head);
});

server.listen(PROXY_PORT, "0.0.0.0", () => {
  process.stdout.write(`auth-proxy listening on :${PROXY_PORT}\n`);
});
