import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export function readConfigFromString(content: string, key: string): string | undefined {
  return content.match(new RegExp(`^${key}=(.+)$`, "m"))?.[1]?.trim();
}

export function readConfig(
  key: string,
  configPath: string = resolve(process.cwd(), ".site-config"),
): string | undefined {
  if (!existsSync(configPath)) return undefined;
  return readConfigFromString(readFileSync(configPath, "utf-8"), key);
}
