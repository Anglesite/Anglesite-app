import type http from "node:http";
import type net from "node:net";
import { safeEqual } from "./crypto.js";

export { safeEqual };

export function extractBearer(authHeader: string | undefined): string {
  if (!authHeader) return "";
  return authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
}

export function isAuthorized(
  authHeader: string | undefined,
  expected: string,
): boolean {
  const token = extractBearer(authHeader);
  return token.length > 0 && safeEqual(token, expected);
}

export function mcpAuthMiddleware(
  expectedToken: string,
): (
  req: http.IncomingMessage,
  res: http.ServerResponse,
  next: () => void,
) => void {
  return (req, res, next) => {
    if (!isAuthorized(req.headers.authorization, expectedToken)) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
    next();
  };
}

export function mcpAuthUpgradeGuard(
  expectedToken: string,
  req: http.IncomingMessage,
  socket: net.Socket,
): boolean {
  if (!isAuthorized(req.headers.authorization, expectedToken)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return false;
  }
  return true;
}
