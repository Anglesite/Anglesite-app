-- @dwk/indieauth 0.1.0-beta.3 authorization-code and issued-token store.
-- Kept as a Wrangler D1 migration because the request handler intentionally does not mutate its
-- schema at startup; SocialWorkerProvisionCommand applies this before deploying the endpoint.

CREATE TABLE IF NOT EXISTS authorization_codes (
  code TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  scope TEXT NOT NULL,
  me TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  code_challenge_method TEXT NOT NULL,
  profile TEXT,
  resource TEXT,
  expires_at INTEGER NOT NULL,
  used INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS access_tokens (
  jti TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  me TEXT NOT NULL,
  scope TEXT NOT NULL,
  jkt TEXT NOT NULL,
  issued_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0
);
