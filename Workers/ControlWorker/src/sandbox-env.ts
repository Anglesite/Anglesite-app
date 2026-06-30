import { Sandbox } from "@cloudflare/sandbox";
export { Sandbox };

export interface Env {
  Sandbox: DurableObjectNamespace<Sandbox>;
  CONTROL_API_SECRET: string;
  SITE_DIR: string;
  ASTRO_PORT: string;
  PROXY_PORT: string;
  MCP_PORT: string;
}
