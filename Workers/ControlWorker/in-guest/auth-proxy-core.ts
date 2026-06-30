import { safeEqual } from "./crypto.js";

export { safeEqual };

export const TOKEN_COOKIE_NAME = "session_token";

export function extractCookie(cookieHeader: string | undefined): string {
  if (!cookieHeader) return "";
  for (const part of cookieHeader.split(";")) {
    const [k, v] = part.trim().split("=", 2);
    if (k === TOKEN_COOKIE_NAME) return v ?? "";
  }
  return "";
}

export function isAuthorized(
  cookieHeader: string | undefined,
  expected: string,
): boolean {
  const cookie = extractCookie(cookieHeader);
  return cookie.length > 0 && safeEqual(cookie, expected);
}
