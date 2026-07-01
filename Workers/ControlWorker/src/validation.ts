import type { StartBody, StatusBody, StopBody } from "./types.js";

const REPO_RE = /^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+(?:\.git)?$/;
const REF_RE = /^[A-Za-z0-9._\-/]+$/;
const TOKEN_RE = /^[0-9a-f]{64}$/;
const SITE_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

export interface ValidationError {
  field: string;
  message: string;
}

export function isValidationError(v: unknown): v is ValidationError {
  return typeof v === "object" && v !== null && "field" in v && "message" in v;
}

export function validateStartBody(
  body: unknown,
): StartBody | ValidationError {
  if (typeof body !== "object" || body === null)
    return { field: "body", message: "must be a JSON object" };
  const b = body as Record<string, unknown>;
  if (typeof b.siteID !== "string" || !SITE_ID_RE.test(b.siteID))
    return { field: "siteID", message: "1-128 chars, alphanumerics and - _ only" };
  if (typeof b.gitRemote !== "string" || !REPO_RE.test(b.gitRemote))
    return {
      field: "gitRemote",
      message: "must be https://github.com/owner/repo[.git]",
    };
  if (typeof b.gitRef !== "string" || !REF_RE.test(b.gitRef) || /\.\./.test(b.gitRef) || b.gitRef.startsWith("/"))
    return { field: "gitRef", message: "alphanumerics, . _ - / only; no .. or leading /" };
  if (typeof b.token !== "string" || !TOKEN_RE.test(b.token))
    return { field: "token", message: "must be 64 lowercase hex chars" };
  return {
    siteID: b.siteID,
    gitRemote: b.gitRemote,
    gitRef: b.gitRef,
    token: b.token,
  };
}

export function validateStopBody(body: unknown): StopBody | ValidationError {
  return validateSiteBody(body);
}

export function validateStatusBody(body: unknown): StatusBody | ValidationError {
  return validateSiteBody(body);
}

function validateSiteBody(body: unknown): StopBody | ValidationError {
  if (typeof body !== "object" || body === null)
    return { field: "body", message: "must be a JSON object" };
  const b = body as Record<string, unknown>;
  if (typeof b.siteID !== "string" || !SITE_ID_RE.test(b.siteID))
    return { field: "siteID", message: "1-128 chars, alphanumerics and - _ only" };
  return { siteID: b.siteID };
}
